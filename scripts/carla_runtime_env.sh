#!/usr/bin/env bash
# Configure and validate the graphics/audio runtime used by CARLA/Unreal.
# This file is sourced by jobs/slurm_run.sh after NVIDIA Container Toolkit has
# mounted the host driver libraries into the container.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "ERROR: source this file; do not execute it in a child shell." >&2
  exit 2
fi

resolve_nvidia_icd() {
  local candidate
  local -a configured_candidates=()

  if [[ -n "${VK_ICD_FILENAMES:-}" ]]; then
    IFS=: read -r -a configured_candidates <<< "$VK_ICD_FILENAMES"
  fi

  # NVIDIA Container Toolkit versions have used both locations. Prefer the
  # explicitly configured path, then accept the other standard mount point.
  for candidate in \
    "${configured_candidates[@]}" \
    /etc/vulkan/icd.d/nvidia_icd.json \
    /usr/share/vulkan/icd.d/nvidia_icd.json; do
    [[ -n "$candidate" && -s "$candidate" ]] || continue
    if grep -Eqi 'nvidia|libGLX_nvidia' "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

NVIDIA_ICD="$(resolve_nvidia_icd || true)"
if [[ -z "$NVIDIA_ICD" ]]; then
  echo "ERROR: no non-empty NVIDIA Vulkan ICD JSON was found." >&2
  echo "Expected one of:" >&2
  echo "  /etc/vulkan/icd.d/nvidia_icd.json" >&2
  echo "  /usr/share/vulkan/icd.d/nvidia_icd.json" >&2
  echo "Start the container with NVIDIA_DRIVER_CAPABILITIES=all." >&2
  exit 2
fi
export VK_ICD_FILENAMES="$NVIDIA_ICD"

export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"

if ! command -v vulkaninfo >/dev/null 2>&1; then
  echo "ERROR: vulkaninfo is missing from the image." >&2
  exit 2
fi

VULKAN_SUMMARY="$(vulkaninfo --summary 2>&1)" || {
  echo "ERROR: Vulkan could not create an instance with $VK_ICD_FILENAMES." >&2
  printf '%s\n' "$VULKAN_SUMMARY" | tail -40 >&2
  exit 2
}
if ! grep -Eqi 'nvidia' <<< "$VULKAN_SUMMARY"; then
  echo "ERROR: Vulkan selected an ICD, but it did not report an NVIDIA GPU." >&2
  printf '%s\n' "$VULKAN_SUMMARY" | tail -40 >&2
  exit 2
fi

echo "[job] NVIDIA Vulkan ICD: $VK_ICD_FILENAMES"
echo "[job] SDL audio driver: $SDL_AUDIODRIVER"
