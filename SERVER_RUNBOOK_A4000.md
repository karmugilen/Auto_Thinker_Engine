# Server Runbook: Ubuntu 22.04 Docker + RTX A4000

This runbook describes how to install and run Auto Thinker Engine on the
provided compute environment:

- Ubuntu 22.04.5 LTS (Jammy) inside Docker
- x86_64, 24 logical CPUs, Intel i9-12900K
- 62 GiB RAM and 8 GiB swap
- NVIDIA RTX A4000 with 16 GiB VRAM
- NVIDIA driver 580.173.02, host CUDA 13.0
- Approximately 541 GB free storage in the current overlay filesystem

All commands assume Bash. Replace every placeholder path with a path that is
persistent on the server.

## 1. Viability verdict

The workstation is viable for this project, with these limits:

| Workload | Verdict | Explanation |
|---|---|---|
| Tests and environment checks | Yes | CPU and RAM are sufficient. |
| CNN CARLA baseline | Yes | This should be the first training workload. |
| Custom JEPA pretraining | Probably | 224x224 video batches may need a lower batch size. |
| Custom JEPA transfer | Probably | Validate with 10,000 steps first. |
| V-JEPA2 transfer | Uncertain | 16 GiB VRAM is tight because CARLA also uses GPU memory. |
| Full 3-arm, 3-seed comparison | Possible but long | It may run for multiple days and create large outputs. |

The project lockfile installs PyTorch 2.4.1 with CUDA 12.1 user-space
libraries. The host driver is newer and may work, but the actual CUDA test
below is authoritative. Do not install an NVIDIA driver inside the container.

The current disk space should be enough for the code, Python environment,
CARLA, and the approximately 100 GB comma2k19 dataset. Keep checkpoints,
replay data, videos, and logs under persistent storage and monitor free space.

## 2. Publish the project before cloning it

On the development machine, commit and push the current project state:

```bash
cd /home/charan/Project/Auto_Thinker_Engine

git add \
  .gitignore \
  README.md \
  pyproject.toml \
  uv.lock \
  run.py \
  jobs/slurm_run.sh \
  scripts/setup_cardreamer.sh \
  scripts/train_cardreamer.py \
  patches/dreamerv3_torch_compat.patch \
  SERVER_RUNBOOK_A4000.md

git commit -m "Document and prepare headless server execution"
git push origin main
```

The uv.lock file must be included. Otherwise a fresh server clone cannot
reproduce the tested Python environment with uv sync --frozen.

## 3. Request a GPU allocation

If the server uses Slurm, do not train on the login node:

```bash
salloc \
  --gres=gpu:1 \
  --cpus-per-task=8 \
  --mem=64G \
  --time=04:00:00

srun --pty bash -l
```

If your cluster requires a partition or account, add them:

```bash
salloc \
  --partition=<gpu-partition> \
  --account=<account> \
  --gres=gpu:1 \
  --cpus-per-task=8 \
  --mem=64G \
  --time=04:00:00
```

If the Docker container is already running on the allocated workstation and
there is no Slurm, continue in the current terminal.

## 4. Check the server

Run these checks inside the GPU-visible container or allocation:

```bash
uname -a
nvidia-smi
free -h
df -h
python3 --version
git --version
```

Continue only if nvidia-smi shows the RTX A4000. If no GPU appears, the
container was probably started without NVIDIA GPU passthrough. The host
administrator must provide GPU access; installing packages inside the
container will not fix that.

## 5. Define persistent paths

Use a persistent mount. The following is an example:

```bash
export WORK_ROOT=/scratch/$USER/auto_thinker
export PROJECT_DIR=$WORK_ROOT/Auto_Thinker_Engine
export SOFTWARE_DIR=$WORK_ROOT/software
export DATA_ROOT=$WORK_ROOT/datasets/comma2k19
export CACHE_ROOT=$WORK_ROOT/cache
export UV_CACHE_DIR=$CACHE_ROOT/uv
export HF_HOME=$CACHE_ROOT/huggingface

mkdir -p \
  "$WORK_ROOT" \
  "$SOFTWARE_DIR" \
  "$DATA_ROOT" \
  "$CACHE_ROOT" \
  "$UV_CACHE_DIR" \
  "$HF_HOME"
```

If /scratch does not exist, use the persistent directory provided by the
administrator. Do not use a temporary compute-node directory for the dataset
or experiment outputs.

## 6. Clone the repository and submodules

```bash
mkdir -p "$WORK_ROOT"

git clone --recursive \
  https://github.com/<your-user>/<your-repository>.git \
  "$PROJECT_DIR"

cd "$PROJECT_DIR"
git submodule status
```

Both submodules must be populated:

```text
third_party/CarDreamer
third_party/dreamerv3_torch
```

The project pins dreamerv3-torch to the reachable upstream commit
`6ef8646d807cd10ce0c88e10a7e943211e7fc44c`. Setup then applies the tracked
`patches/dreamerv3_torch_compat.patch`, which restores the custom encoder and
CPU optimizer behavior required by this project. This is expected: the
submodule working tree will show the compatibility patch as local changes.
Do not discard those changes before running the tests or training.

If the repository was cloned without submodules:

```bash
git -C "$PROJECT_DIR" submodule update --init --recursive
```

## 7. Install Python 3.10 and project dependencies

If the cluster provides modules, load its Python and CUDA modules. Module names
vary by cluster:

```bash
module load python/3.10
module load cuda/12.1
```

If uv is unavailable:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Install Python 3.10 if necessary:

```bash
uv python install 3.10
```

Install the locked project environment:

```bash
cd "$PROJECT_DIR"
uv sync --frozen --extra dev --extra carla
source .venv/bin/activate

which python
python --version
```

Python must report version 3.10.x.

Do not install the following files into the same environment:

```text
third_party/dreamerv3_torch/requirements.txt
third_party/CarDreamer/pyproject.toml
```

They pin older Gym and NumPy versions. The root pyproject.toml and uv.lock are
the project’s dependency definition.

## 8. Install CARLA 0.9.15

The project expects CARLA 0.9.15. The official release provides the Ubuntu
archive CARLA_0.9.15.tar.gz:

https://github.com/carla-simulator/carla/releases/tag/0.9.15

Download it to persistent storage:

```bash
cd "$SOFTWARE_DIR"

curl -L --fail --retry 3 \
  -o CARLA_0.9.15.tar.gz \
  https://tiny.carla.org/carla-0-9-15-linux

tar -xzf CARLA_0.9.15.tar.gz
find "$SOFTWARE_DIR" -maxdepth 3 -name CarlaUE4.sh -print
```

Set CARLA_ROOT to the directory containing the discovered CarlaUE4.sh. Do not
assume that the archive creates a `CARLA_0.9.15/` directory:

```bash
CARLA_SERVER="$(find "$SOFTWARE_DIR" -maxdepth 3 -type f -name CarlaUE4.sh -print -quit)"
test -n "$CARLA_SERVER" || { echo "CarlaUE4.sh not found"; exit 1; }
export CARLA_ROOT="$(dirname "$CARLA_SERVER")"
test -x "$CARLA_SERVER" && echo "CARLA server found: $CARLA_SERVER"
```

If the archive extracts directly into `$SOFTWARE_DIR`, the command above sets
`CARLA_ROOT=$SOFTWARE_DIR`. If it extracts into a child directory, it sets
`CARLA_ROOT` to that child directory automatically.

CARLA is run without a graphical display using:

```bash
-RenderOffScreen -quality-level=Low -carla-rpc-port=2000
```

The official CARLA documentation describes command-line Linux startup and
Python client connections through port 2000:
https://carla.readthedocs.io/en/0.9.15/tuto_G_getting_started/

## 9. Install the CARLA Python API and CarDreamer runtime

Export the local project paths:

```bash
export PYTHONPATH="$CARLA_ROOT/PythonAPI/carla:$PROJECT_DIR/third_party/CarDreamer:$PROJECT_DIR/third_party/dreamerv3_torch"
```

Run the project helper:

```bash
cd "$PROJECT_DIR"
source .venv/bin/activate
bash scripts/setup_cardreamer.sh "$CARLA_ROOT"
```

The helper checks the submodules, skips the submodule network update when both
directories are already populated, applies the tracked Dreamer compatibility
patch, verifies the locked environment, installs the CARLA Python API, and
runs basic checks.

It deliberately does not install CarDreamer’s own package metadata because
that metadata pins incompatible old Gym and NumPy versions. CarDreamer is used
from the checked-out submodule through PYTHONPATH.

The CARLA 0.9.15 simulator archive commonly contains only Python 2.7 and
Python 3.7 packages. That is not a usable package for this project’s Python
3.10 environment. The official PyPI release provides the Linux CPython 3.10
wheel, so the helper falls back to it when the archive has no `cp310` wheel:

https://pypi.org/project/carla/0.9.15/

If you need to perform that step manually:

```bash
uv pip install --python "$PROJECT_DIR/.venv/bin/python" pip
uv pip install --python "$PROJECT_DIR/.venv/bin/python" "carla==0.9.15"
```

Re-export the paths after the helper exits:

```bash
export CARLA_ROOT=$SOFTWARE_DIR/CARLA_0.9.15
export PYTHONPATH="$CARLA_ROOT/PythonAPI/carla:$PROJECT_DIR/third_party/CarDreamer:$PROJECT_DIR/third_party/dreamerv3_torch"
```

Verify imports:

```bash
python -c "import carla; print('CARLA API:', carla.__file__)"
python -c "import car_dreamer; print('CarDreamer: OK')"
```

## 10. Validate CUDA and dependencies

Run the project checker:

```bash
cd "$PROJECT_DIR"
python run.py doctor --require-cuda --require-carla
```

Run a direct CUDA tensor test:

```bash
python - <<'PY'
import torch

print("Torch:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
print("CUDA device count:", torch.cuda.device_count())

if not torch.cuda.is_available():
    raise SystemExit("CUDA is not visible inside this container")

print("GPU:", torch.cuda.get_device_name(0))
x = torch.randn(2048, 2048, device="cuda")
y = x @ x
print("CUDA tensor test: OK", y.shape)
PY
```

The command must report the RTX A4000 and complete successfully.

## 11. Stage the comma2k19 dataset

The Phase 2 configuration expects:

```text
data/comma2k19
```

Keep the actual data in persistent storage and link it into the project:

```bash
mkdir -p "$PROJECT_DIR/data"

if [ ! -e "$PROJECT_DIR/data/comma2k19" ]; then
  ln -s "$DATA_ROOT" "$PROJECT_DIR/data/comma2k19"
fi

ls -ld "$PROJECT_DIR/data/comma2k19"
```

If the server has internet access:

```bash
cd "$PROJECT_DIR"

python run.py download \
  --output-dir "$DATA_ROOT" \
  --method huggingface
```

If it does not, copy the dataset from another machine:

```bash
rsync -avP \
  /path/to/local/comma2k19/ \
  "$DATA_ROOT/"
```

Verify the expected files:

```bash
python run.py download \
  --output-dir "$DATA_ROOT" \
  --verify
```

The verifier checks video.hevc plus steering and car-speed telemetry. A
partial dataset is useful for development, but full training needs the full
dataset or a substantial subset.

The current downloader’s --chunks option is not a reliable partial-download
control in Hugging Face mode. For development, manually stage one chunk and
then run the verification command.

## 12. Gate 0: run the CARLA smoke test

The job wrapper starts CARLA headlessly, waits for it, runs the smoke test, and
shuts CARLA down.

CARLA/Unreal refuses to start as root. Check the identity before launching:

```bash
id -u
id -un
```

The preferred solution is to run the Docker container or compute job as a
non-root user. If the current container is root, ask the administrator for an
existing non-root account and ensure that account can read and write the CARLA
installation directory. The job wrapper now fails immediately with an
actionable error instead of waiting 30 seconds for a client timeout.

If the container must remain root but contains an existing non-root account,
set `CARLA_RUN_USER` so only the CARLA server is launched through `runuser`:

```bash
getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1, $3}'

CARLA_ROOT="$CARLA_ROOT" \
CARLA_RUN_USER=<existing-non-root-user> \
RUN_MODE=smoke \
bash jobs/slurm_run.sh
```

The CARLA directory must be writable by that account because Unreal creates
runtime files below its installation. If there is no non-root account in the
image, the container must be restarted with a non-root UID; the project cannot
make CARLA accept uid 0 from inside the launcher.

Without Slurm:

```bash
cd "$PROJECT_DIR"

CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=smoke \
bash jobs/slurm_run.sh
```

For the root-container workaround, add `CARLA_RUN_USER=...` to that command.

With Slurm:

```bash
cd "$PROJECT_DIR"

CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=smoke \
sbatch jobs/slurm_run.sh
```

If Slurm starts the job inside a root container, also pass
`CARLA_RUN_USER=<existing-non-root-user>`.

The smoke test checks that CARLA can connect, spawn a vehicle and camera, and
advance 100 synchronous simulation steps. Do not train if it fails.

## 13. Run a short CNN integration test

After Gate 0 succeeds:

```bash
cd "$PROJECT_DIR"

CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=cnn \
STEPS=10000 \
SEED=42 \
bash jobs/slurm_run.sh
```

For a batch allocation:

```bash
CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=cnn \
STEPS=10000 \
SEED=42 \
sbatch jobs/slurm_run.sh
```

Watch GPU memory when using an interactive allocation:

```bash
watch -n 2 nvidia-smi
```

Check generated files:

```bash
find outputs -maxdepth 4 -type f | sort | tail -40
```

## 14. Run the full CNN baseline

Only after the short CNN test succeeds:

```bash
CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=cnn \
STEPS=500000 \
SEED=42 \
sbatch jobs/slurm_run.sh
```

Use scripts/train_cardreamer.py through run.py as the active Phase 1/3
runner. Do not use the old custom scripts that import deprecated components.

## 15. Run JEPA Phase 2

Phase 2 requires the comma2k19 dataset but does not require CARLA to run.

Make a one-epoch path-test configuration:

```bash
cp \
  configs/phase2_jepa_pretrain.yaml \
  "$WORK_ROOT/phase2_smoke.yaml"

sed -i 's/total_epochs: 100/total_epochs: 1/' \
  "$WORK_ROOT/phase2_smoke.yaml"
```

Run the path test:

```bash
DATA_DIR="$DATA_ROOT" \
PHASE2_CONFIG="$WORK_ROOT/phase2_smoke.yaml" \
RUN_MODE=phase2 \
bash jobs/slurm_run.sh
```

Run full JEPA pretraining:

```bash
DATA_DIR="$DATA_ROOT" \
PHASE2_CONFIG=configs/phase2_jepa_pretrain.yaml \
RUN_MODE=phase2 \
sbatch jobs/slurm_run.sh
```

Check the checkpoint:

```bash
test -f outputs/checkpoints/phase2/best.pt \
  && echo "JEPA checkpoint found"
```

Run the linear probe:

```bash
python run.py probe \
  --config configs/phase2_jepa_pretrain.yaml \
  --checkpoint outputs/checkpoints/phase2/best.pt
```

Generate plots:

```bash
python run.py visualize \
  --checkpoint outputs/checkpoints/phase2/best.pt \
  --data-dir data/comma2k19 \
  --output-dir outputs/visualizations
```

## 16. Run custom JEPA transfer

Confirm the checkpoint:

```bash
python run.py doctor \
  --checkpoint outputs/checkpoints/phase2/best.pt
```

Run a short transfer test:

```bash
CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=custom_jepa \
STEPS=10000 \
SEED=42 \
sbatch jobs/slurm_run.sh
```

If successful, run the full arm:

```bash
CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=custom_jepa \
STEPS=500000 \
SEED=42 \
sbatch jobs/slurm_run.sh
```

## 17. Run V-JEPA2 transfer

Keep the Hugging Face cache persistent:

```bash
export HF_HOME="$CACHE_ROOT/huggingface"
mkdir -p "$HF_HOME"
```

Run a short test first:

```bash
CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=vjepa2 \
STEPS=10000 \
SEED=42 \
sbatch jobs/slurm_run.sh
```

If V-JEPA2 runs out of memory, request a GPU with more VRAM before changing
the configuration. The RTX A4000 should not be assumed to support the full
configured V-JEPA2 workload.

## 18. Run the complete comparison

The comparison runs three arms across three seeds, for nine sequential runs:

```bash
CARLA_ROOT="$CARLA_ROOT" \
RUN_MODE=comparison \
STEPS=500000 \
sbatch jobs/slurm_run.sh
```

Do not start it until the smoke test, CNN test, JEPA checkpoint, custom JEPA
test, and V-JEPA2 test all succeed.

The active Phase 3 runner reads configs/phase3_transfer_arms.yaml. The
experiment_contract.yaml file contains older contradictory values and is not
automatically enforced by the active runner. Do not mix those configurations
when reporting a controlled comparison.

## 19. Run simultaneous jobs

If independent jobs run at the same time, use different CARLA ports:

```bash
CARLA_ROOT="$CARLA_ROOT" \
CARLA_PORT=2010 \
RUN_MODE=cnn \
STEPS=500000 \
SEED=42 \
sbatch jobs/slurm_run.sh
```

Use another port, such as 2020, for another job. Keep CARLA_HOST=localhost
for jobs running inside the same container. The active trainer forwards
CARLA_PORT into CarDreamer.

## 20. Monitor jobs and storage

```bash
squeue -u "$USER"
sacct -j <job_id> \
  --format=JobID,State,Elapsed,MaxRSS,AllocTRES%30
tail -f slurm-<job_id>.out
watch -n 2 nvidia-smi
pgrep -af CarlaUE4
ss -ltn | grep ':2000'
du -sh outputs
df -h "$WORK_ROOT"
```

## 21. Common failures

### CUDA is unavailable

Run inside a GPU allocation and check nvidia-smi. If the GPU is not visible,
the container needs to be restarted with host GPU passthrough.

### No module named carla

The simulator archive may not contain a Python 3.10 wheel. Install the
official PyPI package into the project’s uv environment:

```bash
uv pip install --python "$PROJECT_DIR/.venv/bin/python" pip
uv pip install --python "$PROJECT_DIR/.venv/bin/python" "carla==0.9.15"
```

Then rerun:

```bash
python run.py doctor --require-cuda --require-carla
```

### No module named cv2, flask, or shapely

Run:

```bash
uv sync --frozen --extra dev --extra carla
```

Do not install CarDreamer’s old dependency metadata over the root environment.

### CARLA connection refused

Inspect:

```bash
tail -80 outputs/carla_2000.log
ss -ltn | grep ':2000'
```

Make sure the server and smoke test use the same port.

### Out of memory

Start with CNN. For JEPA or V-JEPA2, request more VRAM or create a separate
experiment configuration with a lower batch size. Record any configuration
change because it affects comparison validity.

### uv lock mismatch

Pull the latest repository and verify:

```bash
git pull --ff-only
git status
uv lock --check
```

### Job reaches the time limit

The active trainer saves latest.pt, but it does not yet expose a complete
command-line resume workflow. Do not assume an interrupted run can safely
resume. Request a longer allocation before launching the full comparison.

## 22. Recommended order

```text
1. Request a GPU allocation.
2. Check GPU, RAM, and storage.
3. Clone the repository with submodules.
4. Install the locked Python 3.10 environment.
5. Install CARLA 0.9.15 and its Python API.
6. Run the strict doctor check.
7. Run the CARLA smoke test.
8. Run CNN for 10,000 steps.
9. Run the full CNN baseline.
10. Stage and verify comma2k19.
11. Run JEPA Phase 2.
12. Run the linear probe.
13. Run custom JEPA for 10,000 steps.
14. Run V-JEPA2 for 10,000 steps.
15. Run the full three-arm comparison.
```
