#!/usr/bin/env bash
# Rehearse images/spike/spike.sh on this machine (x86_64 Linux with Docker), for real:
# vLLM CPU image serving, accuracy evals, vllm bench serve, llama.cpp build, GGUF conversion,
# quantization, llama-bench, llama-server evals and the summary. S3 goes to a local emulator
# (moto); the model is a tiny random Qwen2 with the real Qwen2 tokenizer (make_tiny_qwen.py),
# because Hugging Face may be unreachable. Accuracy and speed from this run mean nothing; every
# step succeeding, and every output being well-formed, is what is checked.
#
# REHEARSAL_GPU=1 runs the GPU branch instead: stand-ins answer for `nvidia-smi` (inventory and
# telemetry) and a docker wrapper serves the CUDA image's requests with the CPU image. Everything
# else is the real GPU code path: image choice, flags, telemetry capture, summary, no llama.cpp.
#
# Not rehearsed here: install_tools (dnf, Amazon Linux only), the Hugging Face download,
# the converter's own venv (download.pytorch.org), arm64/KleidiAI, a real GPU and CUDA image.
#
#   make rehearse-spike          (needs: docker, git, cmake, a C++ compiler, jq, uv, moto, AWS CLI v2)
#   make rehearse-spike-gpu
# Report: build/results/rehearsal-<time>/report.md
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 2
VLLM_VERSION=${VLLM_VERSION:-0.33.0}
IMAGE="vllm/vllm-openai-cpu:v$VLLM_VERSION"
PORT=${MOTO_PORT:-5065}
RUN=$(date -u +%Y%m%dT%H%M%SZ)
GPU_MODE=${REHEARSAL_GPU:-0}
LABEL=x86-rehearsal; [ "$GPU_MODE" = 1 ] && LABEL=gpu-rehearsal
RES="$ROOT/build/results/rehearsal-$LABEL-$RUN"
LAB=${REHEARSAL_LAB:-"$ROOT/build/rehearsal-lab"}
BUCKET=inference-lab-artifacts-123456789012-ap-southeast-2
mkdir -p "$RES"
REPORT="$RES/report.md"
PASSED=0; FAILED=0
pass() { echo "| PASS | $1 |" >>"$REPORT"; PASSED=$((PASSED + 1)); }
fail() { echo "| **FAIL** | $1 |" >>"$REPORT"; FAILED=$((FAILED + 1)); }
expect() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

for t in docker git cmake c++ jq uv moto_server aws; do
  command -v "$t" >/dev/null || { echo "missing $t"; exit 2; }
done
docker info >/dev/null 2>&1 || { echo "docker daemon not running"; exit 2; }

# ------------------------------------------------------------------ emulator for S3
WORK=$(mktemp -d)
moto_server -H 127.0.0.1 -p "$PORT" >"$RES/moto.log" 2>&1 &
MOTO_PID=$!
cleanup() { docker rm -f vllm >/dev/null 2>&1; kill "$MOTO_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
for _ in $(seq 30); do curl -sf "http://127.0.0.1:$PORT/moto-api/" >/dev/null && break; sleep 1; done
cat >"$WORK/config" <<EOF
[profile inference-lab]
region = ap-southeast-2
endpoint_url = http://127.0.0.1:$PORT
aws_access_key_id = testing
aws_secret_access_key = testing
EOF
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_CONFIG_FILE="$WORK/config" AWS_SHARED_CREDENTIALS_FILE="$WORK/none" AWS_PROFILE=inference-lab
export AWS_ENDPOINT_URL="http://127.0.0.1:$PORT" AWS_EC2_METADATA_DISABLED=true
aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint=ap-southeast-2 >/dev/null

# ------------------------------------------------------------------ the host's /opt/lab, locally
# A fresh lab each time; keep the llama.cpp clone and the tiny model between runs (slow to make).
mkdir -p "$LAB/cache"
for d in repo results models build-default build-kleidiai venv vllm-venv; do rm -rf "${LAB:?}/$d"; done
rm -f "$LAB"/*.gguf "$LAB"/*.pid
mkdir -p "$LAB/repo" && git ls-files -z | xargs -0 -I{} cp --parents {} "$LAB/repo/"   # like the bundle
git rev-parse HEAD >"$LAB/repo/.bundle-commit"
uv venv -q "$LAB/venv" --python 3.12 && uv pip install -q --python "$LAB/venv/bin/python" httpx anthropic boto3

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
REF=${LLAMA_CPP_REF:-$(git ls-remote --tags --refs https://github.com/ggml-org/llama.cpp 'b[0-9]*' \
  | sed 's|.*refs/tags/||' | sort -V | tail -1)}
if [ ! -f "$LAB/cache/tinyqwen/config.json" ]; then
  [ -d "$LAB/cache/llama-vocab" ] || git clone -q --depth 1 --branch "$REF" \
    https://github.com/ggml-org/llama.cpp "$LAB/cache/llama-vocab"
  docker run --rm -v "$LAB/cache:$LAB/cache" -v "$ROOT/scripts/local_spike:/s:ro" \
    --entrypoint python3 "$IMAGE" -I /s/make_tiny_qwen.py "$LAB/cache/llama-vocab" "$LAB/cache/tinyqwen" \
    >"$RES/make_tiny_qwen.txt" 2>&1 || { echo "could not build the tiny model"; exit 1; }
fi
rm -rf "$LAB/llama.cpp"   # spike.sh clones it itself, at the tag

# The converter needs torch and transformers; the vLLM CPU image has both. Same paths inside.
cat >"$WORK/convert-python" <<EOF
#!/bin/bash
exec docker run --rm -v "$LAB:$LAB" -w "$LAB" --entrypoint python3 "$IMAGE" "\$@"
EOF
chmod +x "$WORK/convert-python"

if [ "$GPU_MODE" = 1 ]; then
  # Stand-ins for a GPU host. nvidia-smi: inventory, -L, and CSV telemetry (with -l, until killed).
  mkdir -p "$WORK/gpu-shim"
  cat >"$WORK/gpu-shim/nvidia-smi" <<'EOF'
#!/bin/bash
case " $* " in
  *" -L "*) echo "GPU 0: NVIDIA L4 (UUID: GPU-00000000-rehearsal) [simulated]" ;;
  *"--query-gpu=timestamp"*)
    echo "timestamp, power.draw [W], utilization.gpu [%], memory.used [MiB], temperature.gpu, clocks.sm [MHz]"
    while :; do echo "$(date '+%Y/%m/%d %H:%M:%S.000'), 61.50 W, 83 %, 19012 MiB, 58, 2040 MHz"
      [[ " $* " == *" -l "* ]] || break; sleep 1; done ;;
  *"--query-gpu="*)
    echo "name, driver_version, memory.total [MiB], power.limit [W], clocks.max.sm [MHz]"
    echo "NVIDIA L4 (simulated), 000.00, 23034 MiB, 72.00 W, 2040 MHz" ;;
  *) echo "NVIDIA-SMI simulated for the rehearsal: 1 x NVIDIA L4" ;;
esac
EOF
  # docker: requests for the CUDA image are served by the CPU image with GPU-only flags removed.
  REAL_DOCKER=$(command -v docker)
  cat >"$WORK/gpu-shim/docker" <<EOF
#!/bin/bash
if [ "\$1" = run ] && [[ " \$* " == *" --gpus "* ]]; then
  echo "original: \$*" >>"$RES/docker-rewrites.log"
  [[ " \$* " == *" --entrypoint nvidia-smi "* ]] && { echo "GPU 0: NVIDIA L4 [simulated, in container]"; exit 0; }
  out=(); skip=0
  for a in "\$@"; do
    if [ \$skip = 1 ]; then skip=0; continue; fi
    case "\$a" in
      --gpus|--gpu-memory-utilization) skip=1; continue ;;   # --ipc host is kept: vLLM needs the shared memory
      # The CPU image sizes its KV cache from VLLM_CPU_KVCACHE_SPACE, not --gpu-memory-utilization.
      vllm/vllm-openai:*) out+=(-e VLLM_CPU_KVCACHE_SPACE=4); a="vllm/vllm-openai-cpu:\${a#vllm/vllm-openai:}" ;;
    esac
    out+=("\$a")
  done
  echo "rewritten: \${out[*]}" >>"$RES/docker-rewrites.log"
  exec "$REAL_DOCKER" "\${out[@]}"
fi
exec "$REAL_DOCKER" "\$@"
EOF
  chmod +x "$WORK/gpu-shim/nvidia-smi" "$WORK/gpu-shim/docker"
  export PATH="$WORK/gpu-shim:$PATH"
fi

cat >"$LAB/spike.env" <<EOF
BUCKET=$BUCKET
RUN_ID=$RUN
LABEL=$LABEL
VLLM_VERSION=$VLLM_VERSION
MODEL_ID=Qwen/Qwen2.5-1.5B-Instruct
MODEL_REVISION=
LLAMA_CPP_REF=$REF
LAB=$LAB
SKIP_STEPS="install_tools"
VLLM_WHEEL_FALLBACK=0
MODEL_LOCAL_DIR=$LAB/cache/tinyqwen
CONVERT_PYTHON=$WORK/convert-python
EOF

# ------------------------------------------------------------------ run it
{
  echo "# Spike rehearsal $(date -u +%FT%TZ)"
  echo
  echo "Real \`images/spike/spike.sh\` on $(uname -m) with $(nproc) CPUs; S3 on moto; tiny random"
  echo "Qwen2 model with the real Qwen2 tokenizer; llama.cpp $REF; $IMAGE. Commit $(git rev-parse --short HEAD)."
  echo
  echo "| Result | Check |"
  echo "|---|---|"
} >"$REPORT"
START=$SECONDS
bash images/spike/spike.sh "$LAB/spike.env" >"$RES/spike.log" 2>&1
echo "spike.sh finished in $(( (SECONDS - START) / 60 )) min" >>"$RES/spike.log"
OUT="$LAB/results"
cp -r "$OUT" "$RES/host-results"

step_ok() { awk -F'\t' -v s="$1" '$1==s{print $2}' "$OUT/steps.tsv" | grep -qx ok; }
COMMON_STEPS="sysinfo download_model vllm_probe vllm_start vllm_record vllm_eval_free vllm_eval_constrained vllm_bench vllm_stop write_summary"
if [ "$GPU_MODE" = 1 ]; then STEPS="$COMMON_STEPS gpu_info"; else STEPS="$COMMON_STEPS llama_build llama_convert llama_bench llama_serve_eval"; fi
for st in $STEPS; do expect "step $st ok" step_ok "$st"; done
expect "install_tools recorded as skipped" grep -qP '^install_tools\tskipped' "$OUT/steps.tsv"
expect "vLLM served from the image (not the wheel fallback)" grep -qx image "$OUT/vllm_method.txt"
expect "vLLM version endpoint answered" jq -e .version "$OUT/vllm_version.json"
expect "Smoke completion returned text" jq -e '.choices[0].message.content' "$OUT/vllm_smoke.json"
EVALS="vllm-$LABEL vllm-constrained-$LABEL"
[ "$GPU_MODE" = 1 ] || EVALS="$EVALS llamacpp-default-q8_0-$LABEL llamacpp-default-q4_k_m-$LABEL"
for n in $EVALS; do
  expect "Eval $n: 65 predictions, 0 transport errors" python3 -c "
import json,sys
s=json.load(open('$OUT/classify/$n/summary.json'))
sys.exit(0 if s['examples']==65 and s['errors']==0 else 1)"
done
expect "Constrained mode returns only valid classes (0 invalid)" python3 -c "
import json,sys;s=json.load(open('$OUT/classify/vllm-constrained-$LABEL/summary.json'));sys.exit(0 if s['scores']['invalid']==0 else 1)"
expect "Eval records the commit it ran from" python3 -c "
import json,sys;s=json.load(open('$OUT/classify/vllm-$LABEL/summary.json'));sys.exit(0 if s['inference_lab_commit'].startswith('$(git rev-parse HEAD)') else 1)"
for c in 1 8; do
  expect "vllm bench serve c=$c: 48 requests completed" jq -e '.completed == 48' "$OUT/vllm_bench_c$c.json"
done
expect "vLLM Prometheus metrics captured" grep -q '^vllm:' "$OUT/vllm_metrics.txt"
expect "Results uploaded to S3 (summary and steps)" bash -c "
  aws s3 ls s3://$BUCKET/spike/$RUN/$LABEL/spike-summary.md && aws s3 ls s3://$BUCKET/spike/$RUN/$LABEL/steps.tsv"
expect "Per-step uploads succeeded (no upload errors logged)" test ! -s "$OUT/upload_errors.txt"
expect "Weights uploaded to S3 once under the model revision" bash -c "
  aws s3 ls --recursive s3://$BUCKET/models/ | grep -q model.safetensors"
expect "Summary is clean: steps table filled, no shell errors" bash -c "
  grep -q 'vllm_start' $OUT/spike-summary.md && ! grep -qE 'command not found|No such file|syntax error' $OUT/spike-summary.md"
expect "No vLLM container left running" bash -c "! docker ps -q -f name=vllm | grep -q ."
if [ "$GPU_MODE" = 1 ]; then
  expect "GPU: the CUDA image was requested, with --gpus all and --ipc host" bash -c "
    grep -q 'image: vllm/vllm-openai:v$VLLM_VERSION' $OUT/vllm_availability.txt && grep -q -- '^original: run -d --name vllm --network host --gpus all --ipc host' $RES/docker-rewrites.log"
  expect "GPU: vLLM sized its cache with --gpu-memory-utilization 0.85" grep -q -- '--gpu-memory-utilization 0.85' "$OUT/vllm_config.txt"
  expect "GPU: CPU-only settings not used" bash -c "! grep -q VLLM_CPU_KVCACHE_SPACE $OUT/vllm_config.txt"
  expect "GPU: inventory and container check recorded" bash -c "grep -q 'NVIDIA L4' $OUT/gpu_info.csv && grep -q 'NVIDIA L4' $OUT/gpu_container_check.txt"
  expect "GPU: telemetry sampled during eval and bench (>= 20 samples)" bash -c "[ \$(wc -l <$OUT/gpu_telemetry.csv) -ge 21 ]"
  expect "GPU: telemetry collector stopped afterwards" bash -c "! pgrep -f 'nvidia-smi --query-gpu=timestam[p]'"
  expect "GPU: summary has GPU inventory and telemetry" bash -c "grep -q 'NVIDIA L4' $OUT/spike-summary.md && grep -q 'power_w: median' $OUT/spike-summary.md"
  expect "GPU: llama.cpp skipped and said so" grep -q 'llama.cpp steps not run' "$OUT/llama_cpp_version.txt"
else
  expect "vLLM image digest recorded" grep -q 'image_digest: vllm/vllm-openai-cpu@sha256:' "$OUT/vllm_config.txt"
  expect "llama.cpp version recorded with commit" grep -q "ref: $REF commit:" "$OUT/llama_cpp_version.txt"
  for q in bf16 q8_0 q4_k_m q4_0; do
    expect "GGUF $q produced" test -s "$LAB/qwen-$q.gguf"
    expect "llama-bench $q: valid JSON with pp512 and tg128" jq -e '[.[] | select(.n_prompt==512 or .n_gen==128)] | length >= 2' "$OUT/llama_bench_default_$q.json"
  done
  expect "GGUF checksums recorded" test "$(wc -l <"$OUT/gguf_sha256.txt")" -eq 4
  expect "Summary: steps, versions, accuracy, vLLM bench and llama-bench sections" bash -c "
    f=$OUT/spike-summary.md; grep -q '## Steps' \$f && grep -q '## Versions' \$f && grep -q '| vllm-$LABEL |' \$f \
    && grep -q 'request_throughput' \$f && grep -q 'llama_bench_default_q8_0' \$f"
fi

{
  echo
  echo "**$PASSED passed, $FAILED failed.** spike.sh took $(( (SECONDS - START) / 60 )) min. Host results: \`$RES/host-results/\`."
  echo
  echo '```'
  column -t "$OUT/steps.tsv" 2>/dev/null || cat "$OUT/steps.tsv"
  echo '```'
} >>"$REPORT"
cat "$REPORT"
[ "$FAILED" -eq 0 ]
