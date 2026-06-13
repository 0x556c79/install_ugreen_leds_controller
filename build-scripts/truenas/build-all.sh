#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"

headers_missing_file="build/headers-missing.txt"
failed_versions=()
truenas_versions=()

is_supported_version() {
  case "$1" in
    TrueNAS-SCALE-Dragonfish/24.04.* | \
    TrueNAS-SCALE-ElectricEel/24.10.* | \
    TrueNAS-SCALE-Fangtooth/25.04.* | \
    TrueNAS-SCALE-Goldeye/25.10.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if (($#)); then
  truenas_versions=("$@")
else
  if ! version_index="$(curl -fsSL https://download.truenas.com/)"; then
    echo "Failed to fetch TrueNAS version list"
    exit 1
  fi

  mapfile -t truenas_versions < <(
    grep -Eo 'TrueNAS-SCALE-[[:alnum:]]+/[0-9]+(\.[0-9]+)*' <<<"${version_index}" \
      | awk '!seen[$0]++'
  )
fi

if ((${#truenas_versions[@]} == 0)); then
  echo "No TrueNAS versions found to build"
  exit 1
fi

mkdir -p build

for version_path in "${truenas_versions[@]}"; do
  if ! is_supported_version "${version_path}"; then
    echo "Skipping unsupported TrueNAS version ${version_path}"
    continue
  fi

  if [[ -f "${headers_missing_file}" ]] \
    && grep -Fxq -- "${version_path}" "${headers_missing_file}"; then
    echo "Skipping ${version_path} because headers are listed in ${headers_missing_file}"
    continue
  fi

  if [[ -f "build/${version_path}/led-ugreen.ko" ]]; then
    echo "Skipping ${version_path}; module already exists"
    continue
  fi

  echo "Building ${version_path}"
  if ! bash build.sh "${version_path}"; then
    failed_versions+=("${version_path}")
  fi
done

find build \
  \( -name 'led-ugreen.ko' -o -name 'headers-missing.txt' -o -name 'idx6011-source.env' \) \
  -print

if ((${#failed_versions[@]})); then
  printf 'Failed to build TrueNAS versions:\n'
  printf '  %s\n' "${failed_versions[@]}"
  exit 1
fi
