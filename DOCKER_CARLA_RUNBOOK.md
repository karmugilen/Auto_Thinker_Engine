# CARLA 0.9.15 Docker Gate 0 Runbook

This is the reproducible A4000 container path for Gate 0. It addresses the
failure mode where CUDA works but CARLA/Unreal cannot render because the
container was started with only `compute,utility` driver capabilities.

The image does not package the CARLA simulator or an NVIDIA driver. CARLA is
kept on persistent host storage, and the NVIDIA Container Toolkit mounts the
host-matched graphics libraries when the container starts. Do not install an
NVIDIA driver inside the image.

## Host prerequisites

The host must have:

- Ubuntu 22.04 or a compatible x86_64 Linux host;
- an RTX A4000 (or compatible NVIDIA GPU) and a working `nvidia-smi`;
- Docker with the NVIDIA Container Toolkit configured for `--gpus all`;
- CARLA 0.9.15 extracted to a persistent directory;
- a CARLA directory writable by the UID that will run the container.

Verify the simulator path before building:

```bash
export REPO_ROOT="$PWD"
export CARLA_HOST_ROOT=/persistent/software/CARLA_0.9.15

test -x "$CARLA_HOST_ROOT/CarlaUE4.sh"
test -f "$CARLA_HOST_ROOT/CarlaUE4/Binaries/Linux/CarlaUE4-Linux-Shipping"
test -w "$CARLA_HOST_ROOT"
```

If the archive extracted into a different directory, set
`CARLA_HOST_ROOT` to the directory containing `CarlaUE4.sh`. The image uses
the stable in-container path `/opt/carla`, so the command below always uses:

```text
CARLA_ROOT=/opt/carla
```

The CARLA Python API is installed from the locked `carla==0.9.15` PyPI wheel;
the simulator binary itself comes from `CARLA_HOST_ROOT`.

## Build the image

Build with the current host UID/GID so the bind-mounted repository, CARLA
installation, and `outputs/` are writable by the same non-root user:

```bash
cd "$REPO_ROOT"
docker build \
  --build-arg USER_UID="$(id -u)" \
  --build-arg USER_GID="$(id -g)" \
  -t auto-thinker:carla-gpu .
```

The Dockerfile installs Python 3.10, the locked project environment, Vulkan
loader/tools, GL/X11/Unreal runtime libraries, and ALSA libraries. It sets
the default `NVIDIA_DRIVER_CAPABILITIES=all`,
`NVIDIA_VISIBLE_DEVICES=all`, `SDL_AUDIODRIVER=dummy`, and
`VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json`.

## Exact container command

Run this command from the repository directory. It is intentionally detached
so the reviewer can use `docker exec` for the checks below:

```bash
docker run -d --name auto-thinker \
  --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e CARLA_ROOT=/opt/carla \
  -e VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json \
  -e SDL_AUDIODRIVER=dummy \
  --shm-size=2g \
  --user "$(id -u):$(id -g)" \
  -v "$PWD":/work \
  -v "$CARLA_HOST_ROOT":/opt/carla:rw \
  -w /work \
  auto-thinker:carla-gpu
```

The container user is non-root; `CARLA_RUN_USER` is therefore not needed.
If an administrator must start the container as root, the image includes
`util-linux` for the existing `CARLA_RUN_USER` workaround, but the preferred
and recommended path is the `--user "$(id -u):$(id -g)"` command above.

## Reviewer verification

First confirm that the runtime injected real graphics libraries. The
`/etc/vulkan/icd.d/nvidia_icd.json` path in the run command must be non-empty;
the repository launcher also accepts the toolkit's alternate
`/usr/share/vulkan/icd.d/nvidia_icd.json` mount and exports the path it uses.

```bash
docker exec auto-thinker bash -lc '
set -Eeuo pipefail
test "$(id -u)" -ne 0
test -s "$VK_ICD_FILENAMES"
grep -Eqi "nvidia|libGLX_nvidia" "$VK_ICD_FILENAMES"
vulkaninfo --summary
python --version
nvidia-smi
'
```

If `test -s` fails or `vulkaninfo` reports `ERROR_INCOMPATIBLE_DRIVER`,
recreate the container with the exact `--gpus all`,
`NVIDIA_DRIVER_CAPABILITIES=all`, and `--shm-size=2g` options. Installing
Python packages will not repair a missing host driver mount.

The normal project setup can then be run inside the container. It keeps the
existing submodule and compatibility-patch checks:

```bash
docker exec auto-thinker bash -lc \
  'bash scripts/setup_cardreamer.sh "$CARLA_ROOT"'
```

Run the required project checks in this order:

```bash
docker exec auto-thinker bash -lc \
  'python run.py doctor --require-cuda --require-carla'

docker exec auto-thinker bash -lc \
  'CARLA_ROOT=/opt/carla RUN_MODE=smoke bash jobs/slurm_run.sh'
```

The expected final line is:

```text
[job] Smoke test passed; no training requested.
```

The launcher starts CARLA with `-RenderOffScreen -nosound`, exports
`SDL_AUDIODRIVER=dummy`, validates the non-empty NVIDIA ICD with
`vulkaninfo`, and uses the 2 GiB shared-memory allocation. It also writes the
CARLA log to `outputs/carla_2000.log` and stops CARLA when the smoke command
exits.

Do not start the CNN 10k run until this exact smoke command passes:

```bash
docker exec auto-thinker bash -lc \
  'CARLA_ROOT=/opt/carla RUN_MODE=cnn STEPS=10000 SEED=42 bash jobs/slurm_run.sh'
```
