#!/bin/bash
# Day-1 spike on one EC2 host (Amazon Linux 2023; arm64, x86_64, or x86_64 + NVIDIA GPU).
# Answers, with evidence:
#   1. Does vLLM serve Qwen2.5-1.5B-Instruct here (CPU image on CPU hosts, CUDA image on the GPU
#      host), how (image or wheel), in BF16?
#   2. CPU hosts: does llama.cpp build with KleidiAI (arm64), and what does it change (A/B)?
#   3. Accuracy of each server on the classification dataset (same harness as the Codespace).
# Every step is recorded in steps.tsv; a failed step is logged and the rest still run.
# Numbers from this script are spike evidence (one repetition), never report numbers.
#
# Optional settings in the env file (unset on EC2; the local rehearsal sets them):
#   LAB=<dir>              work directory (default /opt/lab)
#   SKIP_STEPS="a b"       step names to skip (the rehearsal skips install_tools)
#   MODEL_LOCAL_DIR=<dir>  copy weights from here instead of Hugging Face
#   CONVERT_PYTHON=<cmd>   Python with the GGUF converter's dependencies already installed
#   VLLM_WHEEL_FALLBACK=0  do not try a pip-installed vLLM if the image fails
set -uo pipefail
# shellcheck source=/dev/null
source "$1"
# cloud-init runs user-data without HOME; set it before PATH uses it (uv installs to ~/.local/bin).
export HOME=${HOME:-/root}
export AWS_DEFAULT_REGION=ap-southeast-2 PATH=$HOME/.local/bin:$PATH
LAB=${LAB:-/opt/lab}; REPO=$LAB/repo; OUT=$LAB/results; MODEL_DIR=$LAB/models/qwen
SERVED=qwen2.5-1.5b-instruct; DEST="s3://$BUCKET/spike/$RUN_ID/$LABEL"
ARCH=$(uname -m); NPROC=$(nproc)
GPU=0; command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && GPU=1
SKIP_STEPS=" ${SKIP_STEPS:-} "
mkdir -p "$OUT" "$MODEL_DIR"
printf 'step\tstatus\tseconds\n' > "$OUT/steps.tsv"

step() {  # step <name> <function...>
  local name=$1 t0=$SECONDS s; shift
  echo "=== $name"
  if [[ "$SKIP_STEPS" == *" $name "* ]]; then s=skipped
  elif "$@"; then s=ok
  else s="failed($?)"; fi
  printf '%s\t%s\t%s\n' "$name" "$s" "$((SECONDS - t0))" >> "$OUT/steps.tsv"
  # Partial results survive a crash or the hard cap. A failed upload is recorded, never hidden.
  aws s3 sync --quiet "$OUT" "$DEST/" || echo "$(date -u +%FT%TZ) upload after $name failed" >> "$OUT/upload_errors.txt"
  [ "$s" = ok ] || [ "$s" = skipped ]
}

wait_health() {  # wait_health <url> <seconds> [container]: fails at once if the container exits
  local end=$((SECONDS + $2))
  while [ $SECONDS -lt $end ]; do
    curl -sf "$1" >/dev/null && return 0
    if [ -n "${3:-}" ] && [ "$(docker inspect -f '{{.State.Running}}' "$3" 2>/dev/null)" != true ]; then
      echo "container $3 is not running (exit code $(docker inspect -f '{{.State.ExitCode}}' "$3" 2>/dev/null))"
      return 1
    fi
    sleep 5
  done
  echo "no health after $2 s"; return 1
}

eval_backend() {  # eval_backend <name> [--constrained]
  (cd "$REPO" && "$LAB/venv/bin/python" -m bench.classify.run openai \
    --base-url http://127.0.0.1:8000 --model "$SERVED" --name "$1" --run-dir "$OUT" "${@:2}")
}

# ---------------------------------------------------------------------------
install_tools() {
  dnf install -y -q docker git cmake gcc gcc-c++ make jq >/dev/null
  systemctl start docker
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
  uv venv -q "$LAB/venv" --python 3.12
  uv pip install -q --python "$LAB/venv/bin/python" anthropic boto3 httpx huggingface_hub
}

sysinfo() {
  local tok; tok=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
  {
    echo "instance_type: $(curl -s -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/instance-type)"
    echo "az: $(curl -s -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
    echo "arch: $ARCH  nproc: $NPROC  gpu: $GPU  smt_active: $(cat /sys/devices/system/cpu/smt/active 2>/dev/null)"
    echo "kernel: $(uname -r)"; free -g; lscpu
    echo "--- cpu flags of interest"
    grep -m1 -E '^(flags|Features)' /proc/cpuinfo | grep -oE '\b(bf16|i8mm|sve|sve2|asimddp|svebf16|sme|avx512f|avx512_bf16|amx_bf16|amx_int8|amx_tile|avx512_vnni)\b' | sort -u | tr '\n' ' '
    echo; grep -m1 -E '^(flags|Features)' /proc/cpuinfo
  } > "$OUT/sysinfo.txt" 2>&1
}

gpu_info() {  # GPU host only: driver, CUDA, and that a container can see the GPU
  nvidia-smi > "$OUT/gpu_nvidia_smi.txt" 2>&1 || return 1
  nvidia-smi --query-gpu=name,driver_version,memory.total,power.limit,clocks.max.sm \
    --format=csv > "$OUT/gpu_info.csv" || return 1
  docker run --rm --gpus all --entrypoint nvidia-smi "$VLLM_IMAGE" -L > "$OUT/gpu_container_check.txt" 2>&1
}

download_model() {
  if [ -n "${MODEL_LOCAL_DIR:-}" ]; then
    cp -r "$MODEL_LOCAL_DIR"/. "$MODEL_DIR"/
    printf 'model_id: %s\nrequested: local\nresolved_sha: local-%s\n' "$MODEL_ID" \
      "$(sha256sum "$MODEL_DIR/config.json" | cut -c1-12)" > "$OUT/model_revision.txt"
  else
    "$LAB/venv/bin/python" - <<PY || return 1
from huggingface_hub import HfApi, snapshot_download
rev = "$MODEL_REVISION" or "main"
info = HfApi().model_info("$MODEL_ID", revision=rev)
snapshot_download("$MODEL_ID", revision=info.sha, local_dir="$MODEL_DIR",
                  allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "LICENSE"])
open("$OUT/model_revision.txt", "w").write(f"model_id: $MODEL_ID\nrequested: {rev}\nresolved_sha: {info.sha}\n")
PY
  fi
  local sha; sha=$(awk '/resolved_sha/{print $2}' "$OUT/model_revision.txt")
  du -sh "$MODEL_DIR" >> "$OUT/model_revision.txt"
  # Weights to S3 once; later backends load from there (no repeated Hugging Face downloads).
  aws s3 ls "s3://$BUCKET/models/$MODEL_ID/$sha/config.json" >/dev/null 2>&1 || \
    aws s3 sync --quiet "$MODEL_DIR" "s3://$BUCKET/models/$MODEL_ID/$sha/" --exclude ".cache/*"
}

# ---------------------------------------------------------------------------
# vLLM: the official image first (what Kubernetes will run), a wheel second.
# KV cache per token, Qwen2.5-1.5B BF16: 28 layers x 2 KV heads x 128 dim x 2 (K,V) x 2 bytes
# = 28 KiB. 32 sequences x 4096 tokens = 3.5 GiB, so 4 GiB covers the worst case and leaves
# room on a 16 GiB host for 3 GiB of weights and the runtime. On the GPU (L4, 24 GB) vLLM
# sizes the cache itself from --gpu-memory-utilization.
KV_GIB=4
# vLLM wants many open files. Ask for 65536, but never more than this host allows: a limit above
# the Docker daemon's own hard limit makes the container fail to start.
NOFILE=$(ulimit -Hn); { [ "$NOFILE" = unlimited ] || [ "$NOFILE" -gt 65536 ]; } && NOFILE=65536
VLLM_ARGS=(--served-model-name "$SERVED" --dtype bfloat16 --max-model-len 4096
           --max-num-seqs 32 --seed 1234 --host 127.0.0.1 --port 8000)
if [ "$GPU" = 1 ]; then
  VLLM_IMAGE="vllm/vllm-openai:v$VLLM_VERSION"
  VLLM_RUN=(--gpus all --ipc host --ulimit "nofile=$NOFILE:$NOFILE")
  VLLM_ARGS+=(--gpu-memory-utilization 0.85)
  VLLM_ENV_DESC="(GPU: cache sized by --gpu-memory-utilization 0.85)"
else
  VLLM_IMAGE="vllm/vllm-openai-cpu:v$VLLM_VERSION"
  VLLM_RUN=(--shm-size 4g --security-opt seccomp=unconfined --cap-add SYS_NICE --ulimit "nofile=$NOFILE:$NOFILE"
            -e "VLLM_CPU_KVCACHE_SPACE=$KV_GIB" -e VLLM_CPU_OMP_THREADS_BIND=auto)
  VLLM_ENV_DESC="VLLM_CPU_KVCACHE_SPACE=$KV_GIB VLLM_CPU_OMP_THREADS_BIND=auto"
fi

vllm_probe() {
  {
    echo "image: $VLLM_IMAGE"
    docker manifest inspect "$VLLM_IMAGE" 2>&1 | jq -r '.manifests[]?.platform | "\(.os)/\(.architecture)"' 2>&1
    echo "--- release assets containing cpu (GitHub API)"
    curl -s -m 20 "https://api.github.com/repos/vllm-project/vllm/releases/tags/v$VLLM_VERSION" | jq -r '.assets[]?.name | select(test("cpu"))' 2>&1
  } > "$OUT/vllm_availability.txt" 2>&1
}

vllm_start_image() {
  local plat=amd64; [ "$ARCH" = aarch64 ] && plat=arm64
  grep -q "linux/$plat" "$OUT/vllm_availability.txt" || { echo "no $plat image"; return 1; }
  docker run -d --name vllm --network host "${VLLM_RUN[@]}" \
    -v "$MODEL_DIR:/models/qwen:ro" -v "$OUT:/results" \
    --entrypoint vllm "$VLLM_IMAGE" serve /models/qwen "${VLLM_ARGS[@]}" \
    > "$OUT/vllm_docker_run.txt" 2>&1 || { docker rm -f vllm >/dev/null 2>&1; return 1; }
  echo "image" > "$OUT/vllm_method.txt"
  wait_health http://127.0.0.1:8000/health 1200 vllm >> "$OUT/vllm_docker_run.txt" || {
    docker logs vllm > "$OUT/vllm_image_failure.log" 2>&1
    docker inspect -f 'exit={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} error={{.State.Error}}' vllm \
      >> "$OUT/vllm_image_failure.log" 2>&1
    docker rm -f vllm >/dev/null; return 1; }
}

vllm_start_wheel() {
  local spec
  if [ "$GPU" = 1 ]; then
    spec="vllm==$VLLM_VERSION"   # the PyPI wheel is the CUDA build
  else
    local suffix=x86_64; [ "$ARCH" = aarch64 ] && suffix=aarch64
    spec=$(curl -s -m 20 "https://api.github.com/repos/vllm-project/vllm/releases/tags/v$VLLM_VERSION" \
      | jq -r --arg a "$suffix" '.assets[]? | select((.name|test("cpu")) and (.name|test($a)) and (.name|endswith(".whl"))) | .browser_download_url' | head -1)
    [ -n "$spec" ] || { echo "no CPU wheel for $suffix"; return 1; }
  fi
  uv venv -q "$LAB/vllm-venv" --python 3.12
  if [ "$GPU" = 1 ]; then
    uv pip install -q --python "$LAB/vllm-venv/bin/python" "$spec" || return 1
  else
    uv pip install -q --python "$LAB/vllm-venv/bin/python" "$spec" \
      --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match || return 1
  fi
  echo "wheel $spec" > "$OUT/vllm_method.txt"
  VLLM_CPU_KVCACHE_SPACE=$KV_GIB VLLM_CPU_OMP_THREADS_BIND=auto nohup "$LAB/vllm-venv/bin/vllm" serve \
    "$MODEL_DIR" "${VLLM_ARGS[@]}" > "$OUT/vllm_server.log" 2>&1 &
  echo $! > "$LAB/vllm.pid"
  wait_health http://127.0.0.1:8000/health 1200
}

vllm_start() {
  vllm_start_image && return 0
  [ "${VLLM_WHEEL_FALLBACK:-1}" = 1 ] || { echo "image failed; wheel fallback disabled"; return 1; }
  vllm_start_wheel
}

vllm_record() {
  {
    echo "method: $(cat "$OUT/vllm_method.txt")"
    docker image inspect --format 'image_digest: {{index .RepoDigests 0}}' "$VLLM_IMAGE" 2>/dev/null
    echo "env: $VLLM_ENV_DESC"
    echo "args: ${VLLM_ARGS[*]}"
  } > "$OUT/vllm_config.txt"
  docker logs vllm 2>&1 | grep -E 'OMP_NUM_THREADS|threads|NUMA|KV cache|kv_cache|GPU blocks|CPU blocks' \
    | head -20 >> "$OUT/vllm_config.txt" || true
  curl -s http://127.0.0.1:8000/version > "$OUT/vllm_version.json"
  curl -s http://127.0.0.1:8000/v1/models > "$OUT/vllm_models.json"
  curl -s http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' -d \
    "{\"model\":\"$SERVED\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK.\"}],\"max_tokens\":8,\"temperature\":0}" \
    > "$OUT/vllm_smoke.json"
  jq -e '.choices[0].message.content' "$OUT/vllm_smoke.json" >/dev/null
}

telemetry_start() {  # GPU host: 1 s samples of power, utilisation and memory during the run
  [ "$GPU" = 1 ] || return 0
  nvidia-smi --query-gpu=timestamp,power.draw,utilization.gpu,memory.used,temperature.gpu,clocks.sm \
    --format=csv -l 1 > "$OUT/gpu_telemetry.csv" 2>&1 &
  echo $! > "$LAB/telemetry.pid"
}

telemetry_stop() {
  [ -f "$LAB/telemetry.pid" ] && kill "$(cat "$LAB/telemetry.pid")" 2>/dev/null
  rm -f "$LAB/telemetry.pid"; return 0
}

vllm_bench() {  # spike-only throughput probe; the real harness comes on Day 2
  local bench=(vllm bench serve --backend openai-chat --base-url http://127.0.0.1:8000
    --endpoint /v1/chat/completions --model "$SERVED" --dataset-name random
    --random-input-len 512 --random-output-len 64 --num-prompts 48 --seed 1234 --save-result)
  local rc=0
  for c in 1 8; do
    if docker ps -q -f name=vllm | grep -q .; then
      docker exec vllm "${bench[@]}" --tokenizer /models/qwen --max-concurrency "$c" \
        --result-dir /results --result-filename "vllm_bench_c$c.json" > "$OUT/vllm_bench_c$c.txt" 2>&1 || rc=1
    else
      "$LAB/vllm-venv/bin/vllm" "${bench[@]:1}" --tokenizer "$MODEL_DIR" --max-concurrency "$c" \
        --result-dir "$OUT" --result-filename "vllm_bench_c$c.json" > "$OUT/vllm_bench_c$c.txt" 2>&1 || rc=1
    fi
  done
  curl -s http://127.0.0.1:8000/metrics > "$OUT/vllm_metrics.txt"
  return $rc
}

vllm_stop() {
  # Only a container that still exists has a log worth keeping (do not overwrite a failure log).
  docker inspect vllm >/dev/null 2>&1 && docker logs vllm > "$OUT/vllm_server.log" 2>&1
  docker rm -f vllm >/dev/null 2>&1 || true
  [ -f "$LAB/vllm.pid" ] && kill "$(cat "$LAB/vllm.pid")" 2>/dev/null
  sleep 5; return 0
}

# ---------------------------------------------------------------------------
# llama.cpp (CPU hosts): build default and (arm64) KleidiAI variants from the same tag; convert
# the same weights to GGUF ourselves so every backend serves the same revision.
llama_build() {
  local ref=$LLAMA_CPP_REF
  [ -n "$ref" ] || ref=$(curl -s -m 20 https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | jq -r '.tag_name // empty' 2>/dev/null)
  # Fallback without the GitHub API (rate limits, proxies): newest numbered release tag.
  [ -n "$ref" ] || ref=$(git ls-remote --tags --refs https://github.com/ggml-org/llama.cpp 'b[0-9]*' \
    | sed 's|.*refs/tags/||' | sort -V | tail -1)
  [ -n "$ref" ] || { echo "could not resolve a llama.cpp release tag"; return 1; }
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
  local py
  if [ -n "${CONVERT_PYTHON:-}" ]; then
    py=$CONVERT_PYTHON
  else
    uv venv -q "$LAB/conv-venv" --python 3.12
    uv pip install -q --python "$LAB/conv-venv/bin/python" \
      -r "$LAB/llama.cpp/requirements/requirements-convert_hf_to_gguf.txt" \
      --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match || return 1
    py=$LAB/conv-venv/bin/python
  fi
  local conv=$LAB/llama.cpp/convert_hf_to_gguf.py
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
  local threads=4 rc=0; [ "$NPROC" != 4 ] && threads="4,$NPROC"
  for b in "$LAB"/build-*; do
    local v=${b##*build-}
    for g in "$LAB"/qwen-*.gguf; do
      local q; q=$(basename "$g" .gguf); q=${q#qwen-}
      "$b/bin/llama-bench" -m "$g" -t "$threads" -p 512 -n 128 -r 3 -o json \
        > "$OUT/llama_bench_${v}_${q}.json" 2> "$OUT/llama_bench_${v}_${q}.log" || rc=1
    done
  done
  return $rc
}

llama_serve_eval() {
  local v=default rc=0; [ -d "$LAB/build-kleidiai" ] && v=kleidiai
  for q in q8_0 q4_k_m; do
    "$LAB/build-$v/bin/llama-server" -m "$LAB/qwen-$q.gguf" --alias "$SERVED" -t "$NPROC" \
      -c 4096 --host 127.0.0.1 --port 8000 --seed 1234 > "$OUT/llama_server_${v}_$q.log" 2>&1 &
    local pid=$!
    if wait_health http://127.0.0.1:8000/health 300; then
      eval_backend "llamacpp-$v-$q-$LABEL" || rc=1
    else
      echo "llama-server $q did not become healthy"; rc=1
    fi
    kill $pid; wait $pid 2>/dev/null; sleep 3
  done
  return $rc
}

table() { column -t "$1" 2>/dev/null || cat "$1"; }   # column may be absent on minimal images

write_summary() {
  {
    echo "# Spike: $LABEL ($ARCH, $NPROC vCPU, gpu=$GPU) run $RUN_ID"
    echo; echo '```'; head -3 "$OUT/sysinfo.txt"; grep -A1 'flags of interest' "$OUT/sysinfo.txt" | tail -1
    [ -f "$OUT/gpu_info.csv" ] && cat "$OUT/gpu_info.csv"
    echo '```'
    echo; echo "## Steps"; echo; echo '```'; table "$OUT/steps.tsv"; echo '```'
    echo; echo "## Versions"; echo; echo '```'
    for f in model_revision.txt vllm_config.txt vllm_version.json llama_cpp_version.txt; do
      [ -f "$OUT/$f" ] && { cat "$OUT/$f"; echo; }
    done
    echo; cat "$OUT/vllm_availability.txt" 2>/dev/null; echo '```'
    echo; echo "## Accuracy (classification dataset)"; echo
    tail -n +5 "$OUT/summary.md" 2>/dev/null || echo "(no eval results)"
    echo; echo "## vLLM bench serve (spike, one repetition)"; echo; echo '```'
    for f in "$OUT"/vllm_bench_c*.json; do [ -f "$f" ] && jq -c '{file: (input_filename|split("/")|last), max_concurrency, completed, request_throughput, output_throughput, median_ttft_ms, p99_ttft_ms, median_tpot_ms, p99_tpot_ms}' "$f"; done
    echo '```'
    if [ -s "$OUT/gpu_telemetry.csv" ]; then
      echo; echo "## GPU telemetry during eval and bench"; echo; echo '```'
      python3 - "$OUT/gpu_telemetry.csv" <<'PY'
import csv, statistics, sys
rows = list(csv.reader(open(sys.argv[1])))[1:]
def col(i):
    vals = []
    for r in rows:
        try: vals.append(float(r[i].strip().split()[0]))
        except (IndexError, ValueError): pass
    return vals
for name, i in (("power_w", 1), ("util_pct", 2), ("mem_mib", 3), ("temp_c", 4)):
    v = col(i)
    if v: print(f"{name}: median {statistics.median(v):.0f}, max {max(v):.0f}, samples {len(v)}")
PY
      echo '```'
    fi
    echo; echo "## llama-bench (tokens/s, mean of 3)"; echo; echo '```'
    for f in "$OUT"/llama_bench_*.json; do
      [ -s "$f" ] && jq -r --arg f "$(basename "$f" .json)" '.[] | "\($f)\tthreads=\(.n_threads)\tpp=\(.n_prompt)\ttg=\(.n_gen)\t\(.avg_ts|floor) t/s ±\(.stddev_ts|floor)"' "$f"
    done
    echo '```'
  } > "$OUT/spike-summary.md" 2>&1
}

step install_tools install_tools
step sysinfo sysinfo
[ "$GPU" = 1 ] && step gpu_info gpu_info
step download_model download_model
step vllm_probe vllm_probe
if step vllm_start vllm_start; then
  step vllm_record vllm_record
  telemetry_start
  step vllm_eval_free eval_backend "vllm-$LABEL"
  step vllm_eval_constrained eval_backend "vllm-constrained-$LABEL" --constrained
  step vllm_bench vllm_bench
  telemetry_stop
fi
step vllm_stop vllm_stop
if [ "$GPU" = 1 ]; then
  echo "GPU host: llama.cpp steps not run (vLLM CUDA is the GPU reference)" > "$OUT/llama_cpp_version.txt"
else
  step llama_build llama_build && step llama_convert llama_convert && {
    step llama_bench llama_bench
    step llama_serve_eval llama_serve_eval
  }
fi
step write_summary write_summary
aws s3 sync --quiet "$OUT" "$DEST/" || echo "final upload failed" >&2
echo "spike done"
