#!/usr/bin/env bash
set -euo pipefail

version_path="${1:?missing TrueNAS version path, e.g. TrueNAS-SCALE-Fangtooth/25.04.0}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image_tag="${TRUENAS_KMOD_IMAGE_TAG:-ugreen-idx6011-truenas-build:bookworm}"

mkdir -p "${script_dir}/build"

docker build --tag "${image_tag}" "${script_dir}"
docker run \
  --rm \
  --mount "type=bind,source=${script_dir}/build,target=/build" \
  --mount "type=bind,source=${script_dir}/build-truenas-kmod.sh,target=/build.sh,readonly" \
  --mount "type=bind,source=${script_dir}/extract-truenas-headers.sh,target=/extract-truenas-headers.sh,readonly" \
  --env "CONTROLLER_REPO_URL=${CONTROLLER_REPO_URL:-}" \
  --env "CONTROLLER_REPO_REF=${CONTROLLER_REPO_REF:-}" \
  "${image_tag}" \
  bash -c 'cd /build && bash /build.sh "$@"' bash "${version_path}"
