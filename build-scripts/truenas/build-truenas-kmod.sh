#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_CONTROLLER_REPO_URL="https://github.com/klein0r/ugreen_leds_controller.git"
readonly DEFAULT_CONTROLLER_REPO_REF="480f114bae69ec2bb7003df5d9c13f788ca6ace6"
readonly CONTROLLER_REPO_URL="${CONTROLLER_REPO_URL:-${DEFAULT_CONTROLLER_REPO_URL}}"
readonly CONTROLLER_REPO_REF="${CONTROLLER_REPO_REF:-${DEFAULT_CONTROLLER_REPO_REF}}"

version_path="${1:?missing TrueNAS version path, e.g. TrueNAS-SCALE-Fangtooth/25.04.0}"
version="${version_path##*/}"
url_prefix="https://download.truenas.com/${version_path}/"
update_file="TrueNAS-SCALE-${version}.update"
output_root="$(pwd)"
workdir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

case "${version_path}" in
  TrueNAS-SCALE-Dragonfish/24.04.* | \
  TrueNAS-SCALE-ElectricEel/24.10.* | \
  TrueNAS-SCALE-Fangtooth/25.04.* | \
  TrueNAS-SCALE-Goldeye/25.10.*)
    ;;
  *)
    echo "Unsupported TrueNAS version path: ${version_path}" >&2
    exit 1
    ;;
esac

if [[ -f "${output_root}/${version_path}/led-ugreen.ko" ]]; then
  echo "Module already exists for ${version_path}; skipping"
  exit 0
fi

cd "${workdir}"

# Fetch the signed .update squashfs image. Kernel headers are extracted from it
# because some releases do not publish a packages/Packages.gz index.
if ! wget -nv "${url_prefix}${update_file}"; then
  echo "Update file not available for ${version_path}; skipping"
  exit 0
fi
wget -nv "${url_prefix}${update_file}.sig"

extract_log="${workdir}/extract-truenas-headers.log"
if ! bash /extract-truenas-headers.sh "${update_file}" . 2>&1 | tee "${extract_log}"; then
  if grep -q "Error: header files missing" "${extract_log}"; then
    headers_missing_file="${output_root}/headers-missing.txt"
    touch "${headers_missing_file}"
    if ! grep -Fxq -- "${version_path}" "${headers_missing_file}"; then
      printf '%s\n' "${version_path}" >>"${headers_missing_file}"
    fi
    echo "Header files missing for ${version_path}; skipping because headers match a previous release."
    exit 0
  fi

  exit 1
fi

mkdir tmp
dpkg-deb -R linux-headers-truenas-production-amd64_*.deb tmp
headers_dir="$(find tmp/usr/src -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [[ -z "${headers_dir}" ]]; then
  echo "Unable to locate extracted TrueNAS kernel headers" >&2
  exit 1
fi

git clone --no-tags "${CONTROLLER_REPO_URL}" controller-src
git -C controller-src checkout --detach "${CONTROLLER_REPO_REF}"
controller_commit="$(git -C controller-src rev-parse HEAD)"
kmod_dir="${workdir}/controller-src/kmod"

if [[ ! -f "${kmod_dir}/led-ugreen.c" ]]; then
  echo "Expected kernel module source missing from ${kmod_dir}" >&2
  exit 1
fi

make -C "${kmod_dir}" \
  KDIR="${workdir}/${headers_dir}" \
  PWD="${kmod_dir}"

module_file="${kmod_dir}/led-ugreen.ko"
if [[ ! -f "${module_file}" ]]; then
  echo "Kernel module build did not produce ${module_file}" >&2
  exit 1
fi

if ! strings "${module_file}" \
  | awk '/iDX6011|iDX6012|network_stat2/ { found = 1 } END { exit found ? 0 : 1 }'; then
  echo "Built module does not contain expected iDX6011/iDX6012 LED support markers" >&2
  exit 1
fi

mkdir -p "${output_root}/${version_path}"
cp "${module_file}" "${output_root}/${version_path}/led-ugreen.ko"

{
  printf 'controller_repo_url=%s\n' "${CONTROLLER_REPO_URL}"
  printf 'controller_ref=%s\n' "${CONTROLLER_REPO_REF}"
  printf 'controller_commit=%s\n' "${controller_commit}"
  printf 'builder=install_ugreen_leds_controller/build-scripts/truenas\n'
} >"${output_root}/idx6011-source.env"
