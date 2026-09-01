# CARLA/Unreal needs graphics-capable NVIDIA driver libraries at runtime.
# The NVIDIA Container Toolkit supplies those host-matched libraries when the
# container is started with NVIDIA_DRIVER_CAPABILITIES=all; they must not be
# installed from apt inside the image.
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG USERNAME=carla
ARG USER_UID=1000
ARG USER_GID=1000
ARG UV_VERSION=0.12.7

ENV TZ=Etc/UTC \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all \
    CARLA_ROOT=/opt/carla \
    VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json \
    SDL_AUDIODRIVER=dummy \
    HOME=/home/carla \
    UV_PROJECT_ENVIRONMENT=/opt/auto-thinker/venv \
    PYTHON_BIN=/opt/auto-thinker/venv/bin/python \
    PATH=/opt/auto-thinker/venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        alsa-utils \
        ca-certificates \
        curl \
        ffmpeg \
        git \
        libasound2 \
        libdbus-1-3 \
        libegl1 \
        libfontconfig1 \
        libfreetype6 \
        libgl1 \
        libglvnd0 \
        libglu1-mesa \
        libgtk2.0-0 \
        libpulse0 \
        libsm6 \
        libvulkan1 \
        libwayland-client0 \
        libx11-6 \
        libxau6 \
        libxcb1 \
        libxcursor1 \
        libxdamage1 \
        libxdmcp6 \
        libxext6 \
        libxfixes3 \
        libxi6 \
        libxinerama1 \
        libxkbcommon0 \
        libxkbcommon-x11-0 \
        libxrandr2 \
        libxrender1 \
        libxss1 \
        libxtst6 \
        libxxf86vm1 \
        libomp5 \
        python3.10 \
        python3.10-venv \
        python3-pip \
        util-linux \
        vulkan-tools \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/vulkan/icd.d /opt/auto-thinker /work

# Pin uv independently from the project lockfile. The project dependencies,
# including torch 2.4.1 and CARLA 0.9.15, are still resolved only by uv.lock.
RUN python3.10 -m pip install --no-cache-dir "uv==${UV_VERSION}"

RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home \
        --shell /bin/bash "${USERNAME}" \
    && chown -R "${USER_UID}:${USER_GID}" /opt/auto-thinker /work \
    && chmod 1777 /tmp

WORKDIR /opt/auto-thinker/deps
COPY pyproject.toml uv.lock README.md ./

# Build the locked environment into a path that is not hidden by the runtime
# /work bind mount. --no-install-project is intentional: the checked-out
# source is supplied by the /work bind mount when the container is run.
RUN uv sync --frozen --extra dev --extra carla --no-install-project \
    && chown -R "${USER_UID}:${USER_GID}" /opt/auto-thinker

WORKDIR /work
USER ${USERNAME}
CMD ["sleep", "infinity"]
