#!/usr/bin/env bash
#SBATCH --job-name=driving-world-model
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=2-00:00:00
#
# Headless terminal runner. Submit with, for example:
#   CARLA_ROOT=/scratch/$USER/CARLA_0.9.15 \
#   RUN_MODE=cnn STEPS=10000 sbatch jobs/slurm_run.sh
#
# Supported RUN_MODE values:
#   phase2, smoke, cnn, custom_jepa, vjepa2, comparison

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

PYTHON_BIN="${PYTHON_BIN:-$PROJECT_ROOT/.venv/bin/python}"
RUN_MODE="${RUN_MODE:-cnn}"
TASK="${TASK:-carla_right_turn_simple}"
SEED="${SEED:-42}"
STEPS="${STEPS:-10000}"
CARLA_PORT="${CARLA_PORT:-2000}"
CARLA_HOST="${CARLA_HOST:-localhost}"
DATA_DIR="${DATA_DIR:-$PROJECT_ROOT/data/comma2k19}"
PHASE2_CONFIG="${PHASE2_CONFIG:-configs/phase2_jepa_pretrain.yaml}"
PHASE3_CONFIG="${PHASE3_CONFIG:-configs/phase3_transfer_arms.yaml}"

mkdir -p outputs

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "ERROR: Python executable not found: $PYTHON_BIN" >&2
  echo "Create the environment first, for example: uv sync --frozen" >&2
  exit 2
fi

if [[ "$RUN_MODE" == "phase2" ]]; then
  "$PYTHON_BIN" run.py doctor \
    --require-cuda \
    --require-data \
    --data-dir "$DATA_DIR"
  exec "$PYTHON_BIN" run.py phase2 --config "$PHASE2_CONFIG"
fi

if [[ -z "${CARLA_ROOT:-}" ]]; then
  echo "ERROR: CARLA_ROOT must point to a CARLA 0.9.15 installation." >&2
  exit 2
fi

export PYTHONPATH="$CARLA_ROOT/PythonAPI/carla:$PROJECT_ROOT/third_party/CarDreamer:$PROJECT_ROOT/third_party/dreamerv3_torch${PYTHONPATH:+:$PYTHONPATH}"

"$PYTHON_BIN" run.py doctor --require-cuda --require-carla

CARLA_LOG="${CARLA_LOG:-$PROJECT_ROOT/outputs/carla_${CARLA_PORT}.log}"
echo "[job] Starting CARLA on $CARLA_HOST:$CARLA_PORT"
"$CARLA_ROOT/CarlaUE4.sh" \
  -RenderOffScreen \
  -quality-level="${CARLA_QUALITY_LEVEL:-Low}" \
  -carla-rpc-port="$CARLA_PORT" \
  >"$CARLA_LOG" 2>&1 &
CARLA_PID=$!

cleanup() {
  if kill -0 "$CARLA_PID" 2>/dev/null; then
    echo "[job] Stopping CARLA (pid $CARLA_PID)"
    kill "$CARLA_PID" 2>/dev/null || true
    wait "$CARLA_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

ready=0
for attempt in $(seq 1 12); do
  if "$PYTHON_BIN" run.py smoke --host "$CARLA_HOST" --port "$CARLA_PORT"; then
    ready=1
    break
  fi
  if ! kill -0 "$CARLA_PID" 2>/dev/null; then
    echo "ERROR: CARLA exited before becoming ready. Log: $CARLA_LOG" >&2
    tail -80 "$CARLA_LOG" || true
    exit 1
  fi
  echo "[job] CARLA not ready; retry $attempt/12"
  sleep 5
done

if [[ "$ready" -ne 1 ]]; then
  echo "ERROR: CARLA did not pass the smoke test. Log: $CARLA_LOG" >&2
  exit 1
fi

case "$RUN_MODE" in
  smoke)
    echo "[job] Smoke test passed; no training requested."
    ;;
  cnn|custom_jepa|vjepa2)
    "$PYTHON_BIN" run.py train \
      --arm "$RUN_MODE" \
      --task "$TASK" \
      --seed "$SEED" \
      --steps "$STEPS" \
      --config "$PHASE3_CONFIG"
    ;;
  comparison)
    "$PYTHON_BIN" run.py compare \
      --task "$TASK" \
      --steps "$STEPS" \
      --config "$PHASE3_CONFIG"
    ;;
  *)
    echo "ERROR: unsupported RUN_MODE=$RUN_MODE" >&2
    exit 2
    ;;
esac
