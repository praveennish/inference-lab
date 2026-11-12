#!/bin/bash
# Day-1 spike on one EC2 host (Amazon Linux 2023, arm64 or x86_64). Answers, with evidence:
#   1. Does vLLM's CPU build serve Qwen2.5-1.5B-Instruct here, how (image or wheel), which dtype?
#   2. Does llama.cpp build with KleidiAI (arm64), and what does it change (A/B vs default build)?
#   3. Accuracy of each server on the classification dataset (same harness as the Codespace).
# Every step is recorded in steps.tsv; a failed step is logged and the rest still run.
# Numbers from this script are spike evidence (one repetition), never report numbers.
set -uo pipefail
# shellcheck source=/dev/null
source "$1"
export AWS_DEFAULT_REGION=ap-southeast-2 HOME=/root PATH=/root/.local/bin:$PATH
LAB=/opt/lab; REPO=$LAB/repo; OUT=$LAB/results; MODEL_DIR=$LAB/models/qwen
SERVED=qwen2.5-1.5b-instruct; DEST="s3://$BUCKET/spike/$RUN_ID/$LABEL"
ARCH=$(uname -m); NPROC=$(nproc)
mkdir -p "$OUT" "$MODEL_DIR"
printf 'step\tstatus\tseconds\n' > "$OUT/steps.tsv"

step() {  # step <name> <function>
  local name=$1 t0=$SECONDS; shift
  echo "=== $name"
  if "$@"; then s=ok; else s="failed($?)"; fi
  printf '%s\t%s\t%s\n' "$name" "$s" "$((SECONDS - t0))" >> "$OUT/steps.tsv"
  aws s3 sync -q "$OUT" "$DEST/" || true  # partial results survive a crash or the hard cap
  [ "$s" = ok ]
}

wait_health() {  # wait_health <url> <seconds>
  local end=$((SECONDS + $2))
  while [ $SECONDS -lt $end ]; do curl -sf "$1" >/dev/null && return 0; sleep 5; done
  return 1
}

eval_backend() {  # eval_backend <name> [--constrained]
  (cd "$REPO" && /opt/lab/venv/bin/python -m bench.classify.run openai \
    --base-url http://127.0.0.1:8000 --model "$SERVED" --name "$1" --run-dir "$OUT" "${@:2}")
}

# ---------------------------------------------------------------------------
install_tools() {
  dnf install -y -q docker git cmake gcc gcc-c++ make jq >/dev/null
  systemctl start docker
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
  uv venv -q /opt/lab/venv --python 3.12
  uv pip install -q --python /opt/lab/venv/bin/python anthropic boto3 httpx huggingface_hub
}

sysinfo() {
  local tok; tok=$(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
  {
    echo "instance_type: $(curl -s -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/instance-type)"
    echo "az: $(curl -s -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
    echo "arch: $ARCH  nproc: $NPROC  smt_active: $(cat /sys/devices/system/cpu/smt/active 2>/dev/null)"
    echo "kernel: $(uname -r)"; free -g; lscpu
    echo "--- cpu flags of interest"
    grep -m1 -oE '\b(bf16|i8mm|sve|sve2|asimddp|svebf16|sme|avx512f|avx512_bf16|amx_bf16|amx_int8|amx_tile|avx512_vnni)\b' /proc/cpuinfo | sort -u | tr '\n' ' '
    echo; grep -m1 -E '^(flags|Features)' /proc/cpuinfo
  } > "$OUT/sysinfo.txt" 2>&1
}

download_model() {
  /opt/lab/venv/bin/python - <<PY
from huggingface_hub import HfApi, snapshot_download
rev = "$MODEL_REVISION" or "main"
info = HfApi().model_info("$MODEL_ID", revision=rev)
snapshot_download("$MODEL_ID", revision=info.sha, local_dir="$MODEL_DIR",
                  allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "LICENSE"])
open("$OUT/model_revision.txt", "w").write(f"model_id: $MODEL_ID\nrequested: {rev}\nresolved_sha: {info.sha}\n")
print(info.sha)
PY
  local sha; sha=$(awk '/resolved_sha/{print $2}' "$OUT/model_revision.txt")
  du -sh "$MODEL_DIR" >> "$OUT/model_revision.txt"
  # Weights to S3 once; later backends load from there (no repeated Hugging Face downloads).
  aws s3 ls "s3://$BUCKET/models/$MODEL_ID/$sha/config.json" >/dev/null 2>&1 || \
    aws s3 sync -q "$MODEL_DIR" "s3://$BUCKET/models/$MODEL_ID/$sha/" --exclude ".cache/*"
}

# ---------------------------------------------------------------------------
# vLLM: try the official CPU image first (what Kubernetes will run), the CPU wheel second.
# KV cache per token, Qwen2.5-1.5B BF16: 28 layers x 2 KV heads x 128 dim x 2 (K,V) x 2 bytes
# = 28 KiB. 32 sequences x 4096 tokens = 3.5 GiB, so 4 GiB covers the worst case and leaves
# room on a 16 GiB host for 3 GiB of weights and the runtime.
KV_GIB=4
VLLM_ENV=(-e "VLLM_CPU_KVCACHE_SPACE=$KV_GIB" -e VLLM_CPU_OMP_THREADS_BIND=auto)
VLLM_ARGS=(--served-model-name "$SERVED" --dtype bfloat16 --max-model-len 4096
           --max-num-seqs 32 --seed 1234 --host 127.0.0.1 --port 8000)

vllm_probe() {
  {
    echo "image: vllm/vllm-openai-cpu:v$VLLM_VERSION"
    docker manifest inspect "vllm/vllm-openai-cpu:v$VLLM_VERSION" 2>&1 | jq -r '.manifests[]?.platform | "\(.os)/\(.architecture)"' 2>&1
    echo "--- release assets containing cpu (GitHub API)"
    curl -s "https://api.github.com/repos/vllm-project/vllm/releases/tags/v$VLLM_VERSION" | jq -r '.assets[]?.name | select(test("cpu"))'
  } > "$OUT/vllm_availability.txt" 2>&1
}

vllm_start_image() {
  local plat=amd64; [ "$ARCH" = aarch64 ] && plat=arm64
  grep -q "linux/$plat" "$OUT/vllm_availability.txt" || { echo "no $plat image"; return 1; }
  docker run -d --name vllm --network host --shm-size 4g --security-opt seccomp=unconfined \
    --cap-add SYS_NICE "${VLLM_ENV[@]}" -v "$MODEL_DIR:/models/qwen:ro" -v "$OUT:/results" \
    --entrypoint vllm "vllm/vllm-openai-cpu:v$VLLM_VERSION" serve /models/qwen "${VLLM_ARGS[@]}" \
    || return 1
  echo "image" > "$OUT/vllm_method.txt"
  wait_health http://127.0.0.1:8000/health 1200 || { docker logs vllm > "$OUT/vllm_server.log" 2>&1; docker rm -f vllm; return 1; }
}

vllm_start_wheel() {
  local suffix=x86_64; [ "$ARCH" = aarch64 ] && suffix=aarch64
  local url; url=$(curl -s "https://api.github.com/repos/vllm-project/vllm/releases/tags/v$VLLM_VERSION" \
    | jq -r --arg a "$suffix" '.assets[]? | select((.name|test("cpu")) and (.name|test($a)) and (.name|endswith(".whl"))) | .browser_download_url' | head -1)
  [ -n "$url" ] || { echo "no CPU wheel for $suffix"; return 1; }
  uv venv -q /opt/lab/vllm-venv --python 3.12
  uv pip install -q --python /opt/lab/vllm-venv/bin/python "$url" \
    --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match || return 1
  echo "wheel $url" > "$OUT/vllm_method.txt"
  VLLM_CPU_KVCACHE_SPACE=$KV_GIB VLLM_CPU_OMP_THREADS_BIND=auto nohup /opt/lab/vllm-venv/bin/vllm serve \
    "$MODEL_DIR" "${VLLM_ARGS[@]}" > "$OUT/vllm_server.log" 2>&1 &
  echo $! > /opt/lab/vllm.pid
  wait_health http://127.0.0.1:8000/health 1200
}

vllm_start() { vllm_start_image || vllm_start_wheel; }

vllm_record() {
  {
    echo "method: $(cat "$OUT/vllm_method.txt")"
    docker image inspect --format 'image_digest: {{index .RepoDigests 0}}' \
      "vllm/vllm-openai-cpu:v$VLLM_VERSION" 2>/dev/null
    echo "env: VLLM_CPU_KVCACHE_SPACE=$KV_GIB VLLM_CPU_OMP_THREADS_BIND=auto"
    echo "args: ${VLLM_ARGS[*]}"
  } > "$OUT/vllm_config.txt"
  curl -s http://127.0.0.1:8000/version > "$OUT/vllm_version.json"
  curl -s http://127.0.0.1:8000/v1/models > "$OUT/vllm_models.json"
  curl -s http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' -d \
    "{\"model\":\"$SERVED\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK.\"}],\"max_tokens\":8,\"temperature\":0}" \
    > "$OUT/vllm_smoke.json"
  jq -e '.choices[0].message.content' "$OUT/vllm_smoke.json" >/dev/null
}

vllm_bench() {  # spike-only throughput probe; the real harness comes on Day 2
  local bench=(vllm bench serve --backend openai-chat --base-url http://127.0.0.1:8000
    --endpoint /v1/chat/completions --model "$SERVED" --dataset-name random
    --random-input-len 512 --random-output-len 64 --num-prompts 48 --seed 1234 --save-result)
  for c in 1 8; do
    if docker ps -q -f name=vllm | grep -q .; then
      docker exec vllm "${bench[@]}" --tokenizer /models/qwen --max-concurrency "$c" \
        --result-dir /results --result-filename "vllm_bench_c$c.json" > "$OUT/vllm_bench_c$c.txt" 2>&1
    else
      /opt/lab/vllm-venv/bin/vllm "${bench[@]:1}" --tokenizer "$MODEL_DIR" --max-concurrency "$c" \
        --result-dir "$OUT" --result-filename "vllm_bench_c$c.json" > "$OUT/vllm_bench_c$c.txt" 2>&1
    fi
  done
  curl -s http://127.0.0.1:8000/metrics > "$OUT/vllm_metrics.txt"
}

vllm_stop() {
  docker logs vllm > "$OUT/vllm_server.log" 2>&1 || true
  docker rm -f vllm >/dev/null 2>&1 || true
  [ -f /opt/lab/vllm.pid ] && kill "$(cat /opt/lab/vllm.pid)" 2>/dev/null
  sleep 5; return 0
}

# ---------------------------------------------------------------------------
# llama.cpp: build default and (arm64) KleidiAI variants from the same tag; convert the same
# weights to GGUF ourselves so every backend serves the same revision.
llama_build() {
  local ref=$LLAMA_CPP_REF
  [ -n "$ref" ] || ref=$(curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | jq -r .tag_name)
  git clone -q --depth 1 --branch "$ref" https://github.com/ggml-org/llama.cpp "$LAB/llama.cpp" || return 1
  echo "ref: $ref commit: $(git -C "$LAB/llama.cpp" rev-parse HEAD)" > "$OUT/llama_cpp_version.txt"
  local common=(-DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF)
  local variants=(default); [ "$ARCH" = aarch64 ] && variants+=(kleidiai)
  for v in "${variants[@]}"; do
    local extra=(); [ "$v" = kleidiai ] && extra=(-DGGML_CPU_KLEIDIAI=ON)
    cmake -S "$LAB/llama.cpp" -B "$LAB/build-$v" "${common[@]}" "${extra[@]}" > "$OUT/llama_cmake_$v.txt" 2>&1 || return 1
    cmake --build "$LAB/build-$v" -j "$NPROC" --target llama-server llama-bench llama-quantize \
      > "$OUT/llama_build_$v.txt" 2>&1 || return 1
    grep -iE 'kleidi|GGML_CPU|native|march|mcpu' "$OUT/llama_cmake_$v.txt" "$LAB/build-$v/CMakeCache.txt" \
      | grep -v '^#' | head -40 > "$OUT/llama_flags_$v.txt" || true  # no match is not a build failure
  done
}

llama_convert() {
  uv venv -q /opt/lab/conv-venv --python 3.12
  uv pip install -q --python /opt/lab/conv-venv/bin/python \
    -r "$LAB/llama.cpp/requirements/requirements-convert_hf_to_gguf.txt" \
    --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match || return 1
  local py=/opt/lab/conv-venv/bin/python conv=$LAB/llama.cpp/convert_hf_to_gguf.py
  $py "$conv" "$MODEL_DIR" --outtype bf16 --outfile "$LAB/qwen-bf16.gguf" > "$OUT/gguf_convert.txt" 2>&1 || return 1
  $py "$conv" "$MODEL_DIR" --outtype q8_0 --outfile "$LAB/qwen-q8_0.gguf" >> "$OUT/gguf_convert.txt" 2>&1 || return 1
  for q in Q4_K_M Q4_0; do
    "$LAB/build-default/bin/llama-quantize" "$LAB/qwen-bf16.gguf" "$LAB/qwen-${q,,}.gguf" "$q" \
      >> "$OUT/gguf_convert.txt" 2>&1 || return 1
  done
  ls -l "$LAB"/*.gguf >> "$OUT/gguf_convert.txt"
  sha256sum "$LAB"/*.gguf > "$OUT/gguf_sha256.txt"
}

llama_bench() {  # pp512 / tg128, 3 repetitions, 4 and NPROC threads, every build x quant
  for b in "$LAB"/build-*; do
    local v=${b##*build-}
    for g in "$LAB"/qwen-*.gguf; do
      local q; q=$(basename "$g" .gguf); q=${q#qwen-}
      "$b/bin/llama-bench" -m "$g" -t "4,$NPROC" -p 512 -n 128 -r 3 -o json \
        > "$OUT/llama_bench_${v}_${q}.json" 2> "$OUT/llama_bench_${v}_${q}.log"
    done
  done
}

llama_serve_eval() {
  local v=default; [ -d "$LAB/build-kleidiai" ] && v=kleidiai
  for q in q8_0 q4_k_m; do
    "$LAB/build-$v/bin/llama-server" -m "$LAB/qwen-$q.gguf" --alias "$SERVED" -t "$NPROC" \
      -c 4096 --host 127.0.0.1 --port 8000 --seed 1234 > "$OUT/llama_server_${v}_$q.log" 2>&1 &
    local pid=$!
    if wait_health http://127.0.0.1:8000/health 300; then
      eval_backend "llamacpp-$v-$q-$LABEL"
    fi
    kill $pid; wait $pid 2>/dev/null; sleep 3
  done
}

write_summary() {
  {
    echo "# Spike: $LABEL ($ARCH, $NPROC vCPU) run $RUN_ID"
    echo; echo '```'; head -3 "$OUT/sysinfo.txt"; grep -A1 'flags of interest' "$OUT/sysinfo.txt" | tail -1; echo '```'
    echo; echo "## Steps"; echo; echo '```'; column -t "$OUT/steps.tsv"; echo '```'
    echo; echo "## Versions"; echo; echo '```'
    cat "$OUT/model_revision.txt" "$OUT/vllm_method.txt" "$OUT/vllm_version.json" "$OUT/llama_cpp_version.txt" 2>/dev/null
    echo; cat "$OUT/vllm_availability.txt" 2>/dev/null; echo '```'
    echo; echo "## Accuracy (classification dataset)"; echo
    tail -n +5 "$OUT/summary.md" 2>/dev/null || echo "(no eval results)"
    echo; echo "## vLLM bench serve (spike, one repetition)"; echo; echo '```'
    for f in "$OUT"/vllm_bench_c*.json; do [ -f "$f" ] && jq -c '{file: input_filename, max_concurrency, completed, request_throughput, output_throughput, median_ttft_ms, p99_ttft_ms, median_tpot_ms, p99_tpot_ms}' "$f"; done
    echo '```'; echo; echo "## llama-bench (tokens/s, mean of 3)"; echo; echo '```'
    for f in "$OUT"/llama_bench_*.json; do
      [ -s "$f" ] && jq -r --arg f "$(basename "$f" .json)" '.[] | "\($f)\tthreads=\(.n_threads)\tpp=\(.n_prompt)\ttg=\(.n_gen)\t\(.avg_ts|floor) t/s ±\(.stddev_ts|floor)"' "$f"
    done
    echo '```'
  } > "$OUT/spike-summary.md" 2>&1
}

step install_tools install_tools
step sysinfo sysinfo
step download_model download_model
step vllm_probe vllm_probe
if step vllm_start vllm_start; then
  step vllm_record vllm_record
  step vllm_eval_free eval_backend "vllm-$LABEL"
  step vllm_eval_constrained eval_backend "vllm-constrained-$LABEL" --constrained
  step vllm_bench vllm_bench
fi
step vllm_stop vllm_stop
step llama_build llama_build && step llama_convert llama_convert && {
  step llama_bench llama_bench
  step llama_serve_eval llama_serve_eval
}
step write_summary write_summary
aws s3 sync -q "$OUT" "$DEST/"
echo "spike done"
