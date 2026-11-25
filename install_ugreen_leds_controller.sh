#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Mounts this run made writable, oldest first.
REMOUNTED_RW=()
MODULE_SWAP_ACTIVE=false
# Services the exit hook starts: stopped by this run, or due up on a failed update.
PREVIOUSLY_ACTIVE_LED_SERVICES=()

# Exit hook. The clone stays in the persistent directory so boots work offline.
cleanup() {
    # Bash does not come back here, so a second signal would end the restore halfway.
    trap "" TERM INT HUP
    local i service
    # The exit status is already decided; a failed restore must not change it.
    set +e
    # Every failure between the start of a module swap and the new module running ends here.
    if [ "${MODULE_SWAP_ACTIVE:-false}" = "true" ]; then
        restore_previous_module
    fi
    # Also after a finished swap: a later failure must not leave the monitors down.
    for service in "${PREVIOUSLY_ACTIVE_LED_SERVICES[@]}"; do
        # Signals are ignored here, so a start waiting on the network must not hold the exit.
        systemctl start "${service}" --no-block 2>/dev/null
    done
    for ((i = ${#REMOUNTED_RW[@]} - 1; i >= 0; i--)); do
        mount -o remount,ro "${REMOUNTED_RW[$i]}" || log "Warning: could not remount ${REMOUNTED_RW[$i]} read-only"
    done
}

trap cleanup EXIT

help() {
    echo "Installation helper for ugreen_leds_controller. Needs to be run as root"
    echo
    echo "Syntax: install_ugreen_leds_controller.sh [-h] [-v <version>] [options]"
    echo
    echo "Options:"
    echo "  -h, --help            Print this help"
    echo "  -v <version>          Use predefined TrueNAS version (format: X.Y.Z or X.Y.Z.W)"
    echo "                        If not specified, will be extracted from /etc/version"
    echo
    echo "  --persist-dir <path>  Specify custom persistent storage directory (must be under /mnt/)"
    echo "  --use-current-dir     Use current working directory for leds_controller/ folder (must be under /mnt/)"
    echo "                        A leds_controller/ folder at the script location takes priority"
    echo "  --pool-path <path>    Specify ZFS pool path under /mnt/ for persistent storage"
    echo "  --controller-source <auto|upstream|idx6011>"
    echo "                        Select controller profile (default: auto)"
    echo "                        auto: stable upstream, except exact iDX6011 Pro DMI"
    echo "                        and iDX6011/iDX6012 installs already on idx6011"
    echo "                        upstream: force stable upstream master"
    echo "                        idx6011: force experimental upstream v0.4-beta"
    echo
    echo "  --idx-test <collect|install>  Collect hardware feedback or run a backed-up beta test"
    echo "                        Combines only with --persist-dir, --dry-run and --yes"
    echo "  --uninstall           Fully uninstall: stop services, unload modules, remove installer files"
    echo "                        Other files in the storage folder stay"
    echo "  --dry-run             Show actions without making changes"
    echo "  --yes                 Skip all prompts (non-interactive mode)"
    echo "  --force               Re-clone the upstream scripts and replace the LED configuration with the template"
    echo
    echo "Examples:"
    echo "  # Interactive installation (prompts for persistent directory)"
    echo "  sudo bash install_ugreen_leds_controller.sh"
    echo
    echo "  # Use current directory"
    echo "  cd /mnt/tank/apps && sudo bash install_ugreen_leds_controller.sh --use-current-dir"
    echo
    echo "  # Specify pool path"
    echo "  sudo bash install_ugreen_leds_controller.sh --pool-path tank/apps/ugreen"
    echo
    echo "  # Non-interactive (for TrueNAS Init Scripts)"
    echo "  /bin/bash /mnt/tank/apps/leds_controller/install_ugreen_leds_controller.sh --yes"
    echo
    echo "  # Force the experimental upstream iDX profile"
    echo "  sudo bash install_ugreen_leds_controller.sh --controller-source idx6011"
    echo
    echo "  # Uninstall (preview with --dry-run first)"
    echo "  sudo bash install_ugreen_leds_controller.sh --uninstall --dry-run"
    echo "  sudo bash install_ugreen_leds_controller.sh --uninstall"
    echo
}

readonly REPO_OWNER="miskcoo"
readonly REPO_NAME="ugreen_leds_controller"
readonly SCRIPT_REPO_URL="https://github.com/miskcoo/ugreen_leds_controller.git"
readonly IDX_UPSTREAM_TAG="v0.4-beta"
readonly IDX_UPSTREAM_COMMIT="c830a2293cf5c67c58e5a98ca339b089b2b13fc3"
readonly IDX_ARTIFACT_COMMIT="f7f3766146637858e557b1c5c8dbd1e6e0f7d9b7"
readonly IDX_MODULE_SOURCE="idx6011:miskcoo/ugreen_leds_controller@${IDX_UPSTREAM_TAG}:${IDX_UPSTREAM_COMMIT}:${IDX_ARTIFACT_COMMIT}:build-scripts/truenas/build/tags/${IDX_UPSTREAM_TAG}"
# Uninstall removes these in order; the last four prove the folder is an install, so they go last.
readonly PERSIST_FILES=(ugreen-leds.conf install_ugreen_leds_controller.sh led-ugreen.ko.previous led-ugreen.ko .version .module-source .installer-source)
readonly HELPER_SCRIPTS=(ugreen-diskiomon ugreen-netdevmon ugreen-netdevmon-multi ugreen-probe-leds ugreen-power-led)

# Fetch available TrueNAS builds from GitHub (deferred until after arg parsing)
fetch_truenas_versions() {
    echo "Fetching available TrueNAS versions from GitHub..."
    KMOD_DIRS=$(curl -s --connect-timeout 10 --max-time 30 "${API_URL}" | sed -n 's/.*"name":[[:space:]]*"\(TrueNAS-SCALE-[^"]*\)".*/\1/p' || true)

    if [ -z "${KMOD_DIRS}" ]; then
        echo "Warning: Could not fetch versions from GitHub API, using the built-in codename table"
    fi
}
TRUENAS_VERSION=""
PERSIST_DIR=""
USE_CURRENT_DIR=false
POOL_PATH=""
CONTROLLER_SOURCE="auto"
DRY_RUN=false
AUTO_YES=false
FORCE=false
UNINSTALL=false
IDX_TEST_MODE=""
READONLY_ROOT=false
NEED_MODULE_DOWNLOAD=false
UNINSTALL_LEFT=()

# Usage: require_flag_value "$@" with the flag still in $1
require_flag_value() {
    if [[ -z "${2:-}" || "$2" == -* ]]; then
        echo "Option $1 requires a value." >&2
        exit 1
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            help
            exit 0
            ;;
        -v)
            require_flag_value "$@"
            TRUENAS_VERSION="$2"
            shift 2
            ;;
        --persist-dir)
            require_flag_value "$@"
            PERSIST_DIR="$2"
            shift 2
            ;;
        --use-current-dir)
            USE_CURRENT_DIR=true
            shift
            ;;
        --pool-path)
            require_flag_value "$@"
            POOL_PATH="$2"
            shift 2
            ;;
        --controller-source)
            require_flag_value "$@"
            CONTROLLER_SOURCE="$2"
            shift 2
            ;;
        --idx-test)
            if [ "$#" -lt 2 ] || [[ "$2" != collect && "$2" != install ]]; then
                echo "Use --idx-test collect or --idx-test install." >&2
                exit 1
            fi
            IDX_TEST_MODE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes)
            AUTO_YES=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            help
            exit 1
            ;;
    esac
done

if [ -n "$IDX_TEST_MODE" ] && { [ "$UNINSTALL" = true ] || [ "$FORCE" = true ] || [ -n "$TRUENAS_VERSION" ] || [ "$CONTROLLER_SOURCE" != auto ] || [ "$USE_CURRENT_DIR" = true ] || [ -n "$POOL_PATH" ]; }; then
    echo "--idx-test accepts only --persist-dir, --dry-run and --yes as additional options." >&2
    exit 1
fi

# Ensure script is run as root
if [ "${EUID:-0}" -ne 0 ] && [ "${DRY_RUN}" != "true" ]; then
    echo "Please run as root."
    exit 1
elif [ "${EUID:-0}" -ne 0 ]; then
    echo "Warning: running dry-run as non-root; privileged actions will only be previewed."
fi

# Use current working directory as base
INSTALL_DIR="$(pwd)"

# Logging helper
log() {
    local msg="$*"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$ts] $msg"
}

# Separator helper
log_separator() {
    printf '%*s\n' "80" '' | tr ' ' '-'
}

read_system_product_name() {
    local product=""

    if [ -r "/sys/class/dmi/id/product_name" ]; then
        product=$(sed -n '1p' /sys/class/dmi/id/product_name 2>/dev/null || true)
    fi

    if [ -z "$product" ] && command -v dmidecode >/dev/null 2>&1; then
        product=$(dmidecode --string system-product-name 2>/dev/null || true)
    fi

    echo "$product"
}

select_controller_profile() {
    SYSTEM_PRODUCT_NAME=$(read_system_product_name)
    SCRIPT_EXPECTED_COMMIT=""

    case "${CONTROLLER_SOURCE}" in
        auto)
            if [ "${SYSTEM_PRODUCT_NAME}" = "iDX6011 Pro" ]; then
                CONTROLLER_PROFILE="idx6011"
            else
                CONTROLLER_PROFILE="upstream"
            fi
            ;;
        upstream|idx6011)
            CONTROLLER_PROFILE="${CONTROLLER_SOURCE}"
            ;;
        *)
            echo "Unknown controller source: ${CONTROLLER_SOURCE}" >&2
            echo "Expected one of: auto, upstream, idx6011" >&2
            exit 1
            ;;
    esac

    case "${CONTROLLER_PROFILE}" in
        upstream)
            ARTIFACT_REF="gh-actions"
            ARTIFACT_RAW_REF="refs/heads/gh-actions"
            BUILD_PATH="build-scripts/truenas/build"
            SCRIPT_REPO_BRANCH="master"
            SCRIPT_REPO_REF="master"
            CONTROLLER_MODULE_SOURCE="upstream:miskcoo/ugreen_leds_controller:gh-actions"
            ;;
        idx6011)
            ARTIFACT_REF="${IDX_ARTIFACT_COMMIT}"
            ARTIFACT_RAW_REF="${IDX_ARTIFACT_COMMIT}"
            BUILD_PATH="build-scripts/truenas/build/tags/${IDX_UPSTREAM_TAG}"
            SCRIPT_REPO_BRANCH="${IDX_UPSTREAM_TAG}"
            SCRIPT_REPO_REF="${IDX_UPSTREAM_COMMIT}"
            SCRIPT_EXPECTED_COMMIT="${IDX_UPSTREAM_COMMIT}"
            CONTROLLER_MODULE_SOURCE="${IDX_MODULE_SOURCE}"
            ;;
    esac

    REPO_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${ARTIFACT_RAW_REF}/${BUILD_PATH}"
    API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/${BUILD_PATH}?ref=${ARTIFACT_REF}"
    SCRIPT_SOURCE_MARKER="${CONTROLLER_PROFILE}:${SCRIPT_REPO_URL}:${SCRIPT_REPO_BRANCH}:${SCRIPT_REPO_REF}:${BUILD_PATH}"

    if [ "${CONTROLLER_PROFILE}" = "idx6011" ]; then
        log "Controller source profile: idx6011 (miskcoo/ugreen_leds_controller ${IDX_UPSTREAM_TAG})"
    else
        log "Controller source profile: upstream (miskcoo/ugreen_leds_controller master)"
    fi
    if [ -n "${SYSTEM_PRODUCT_NAME}" ]; then
        log "Detected system product: ${SYSTEM_PRODUCT_NAME}"
    else
        log "System product could not be detected; using profile: ${CONTROLLER_PROFILE}"
    fi

    if [ "${CONTROLLER_SOURCE}" = "idx6011" ] && [ "${SYSTEM_PRODUCT_NAME}" != "iDX6011 Pro" ]; then
        log "WARNING: idx6011 is an experimental manual override for this DMI product; only iDX6011 Pro receives the upstream 2-LAN/6-disk layout automatically"
    fi
}

# Prints the storage folder of the installed service, or nothing. Newer units
# quote the path because a dataset name may contain spaces.
find_installed_persist_dir() {
    local dir
    dir=$(systemctl cat ugreen-diskiomon.service 2>/dev/null |
        sed -n -E 's|^ExecStart="?(/.*)/scripts/ugreen-diskiomon"?$|\1|p' | head -n 1 || true)
    # Canonical like PERSIST_DIR: v2.0.x wrote the path as typed.
    [ -z "${dir}" ] || realpath -m -- "${dir}"
}

# Prints why an install cannot use this canonical path, or nothing.
persist_path_problem() {
    if [[ "$1" != /mnt/* ]]; then
        echo "must be under /mnt/ (on a ZFS pool) to survive TrueNAS updates"
    # These break the sed, awk or systemd handling of the path. A character
    # whitelist would reject non-ASCII names because Post Init may run in the C locale.
    elif [[ "$1" == *[\"\'\\\&\|%\$\`[:cntrl:]]* ]]; then
        echo "must not contain quotes, backslashes, control characters or any of & | % \$ \`"
    fi
}

# Two-stage hardware feedback runner. The normal installer runs as a child so
# every failure can be reported without claiming physical hardware acceptance.
idx_test_find_persist_dir() {
    local detected="" script_dir path_error
    if [ -z "${PERSIST_DIR}" ]; then
        detected=$(find_installed_persist_dir)
        # An off-pool unit cannot host the test; keep looking below.
        [[ "$detected" == /mnt/* ]] || detected=""
        script_dir=$(dirname "$(readlink -f "$0")")
        if [ -n "$detected" ]; then
            PERSIST_DIR="$detected"
        elif [[ "$script_dir" == /mnt/* ]] && [ -f "${script_dir}/led-ugreen.ko" ]; then
            PERSIST_DIR="$script_dir"
        elif [[ "$PWD" == /mnt/* ]] && [ -f "${PWD}/leds_controller/led-ugreen.ko" ]; then
            PERSIST_DIR="${PWD}/leds_controller"
        fi
    fi
    if [ -z "${PERSIST_DIR}" ] && [ "$IDX_TEST_MODE" = collect ]; then
        PERSIST_DIR="/tmp/ugreen-leds-not-configured"
        echo "No existing installation detected; collecting hardware information in /tmp."
        return 0
    fi
    if [ -z "${PERSIST_DIR}" ]; then
        echo "Cannot locate the existing installation. Add --persist-dir /mnt/<pool>/leds_controller." >&2
        return 1
    fi
    PERSIST_DIR=$(realpath -m -- "$PERSIST_DIR")
    case "$PERSIST_DIR" in
        /mnt/*) ;;
        *) echo "Test storage must be under /mnt/." >&2; return 1 ;;
    esac
    # Collection writes nothing to this path; the install child would refuse it after unloading.
    path_error=$(persist_path_problem "$PERSIST_DIR")
    if [ "$IDX_TEST_MODE" = install ] && [ -n "$path_error" ]; then
        echo "Error: persistent directory ${PERSIST_DIR} ${path_error}." >&2
        return 1
    fi
    if [ ! -d "$(dirname "$PERSIST_DIR")" ]; then
        echo "The parent of the persistent directory must exist on your pool." >&2
        return 1
    fi
}

idx_test_capture() {
    local path name value iface
    printf 'Time: '; date -u
    printf 'Stage: %s\nPersistent directory: %s\n' "$IDX_TEST_MODE" "$PERSIST_DIR"
    printf 'TrueNAS: %s\n' "$(cat /etc/version 2>/dev/null || true)"  # /etc/version has no trailing newline
    printf 'Kernel: '; uname -r
    for name in product_name product_version board_name; do
        printf 'DMI %s: ' "$name"
        cat "/sys/class/dmi/id/$name" 2>/dev/null || true
    done
    printf '\nCached module source:\n'; cat "$PERSIST_DIR/.module-source" 2>/dev/null || true
    if [ -f "$PERSIST_DIR/led-ugreen.ko" ]; then
        sha256sum "$PERSIST_DIR/led-ugreen.ko" || true
        modinfo "$PERSIST_DIR/led-ugreen.ko" 2>/dev/null || true
    fi
    printf '\nInstalled module lookup (not proof of the loaded binary):\n'
    modinfo -n led-ugreen 2>/dev/null || true
    for name in version srcversion parameters/write_protocol parameters/num_netdev_leds parameters/num_disk_leds; do
        printf 'Loaded %s: ' "$name"
        cat "/sys/module/led_ugreen/$name" 2>/dev/null || true
    done
    printf '\nLEDs and current triggers:\n'
    for path in /sys/class/leds/*; do
        [ -e "$path" ] || continue
        printf '%s: ' "${path##*/}"
        cat "$path/trigger" 2>/dev/null || true
    done
    printf '\nI2C adapters (list only, no bus scan):\n'
    i2cdetect -l 2>/dev/null || true
    printf '\nStorage, SMBus and network PCI controllers:\n'
    lspci -nn 2>/dev/null | grep -Ei 'SMBus|SATA|RAID|Ethernet|VMD' || true
    printf '\nDisk enumeration (serial numbers omitted):\n'
    lsblk -S -o NAME,HCTL,TRAN,MODEL 2>/dev/null || true
    for path in /sys/block/sd*; do
        [ -e "$path" ] || continue
        printf '%s -> %s\n' "${path##*/}" "$(readlink -f "$path")"
    done
    printf '\nPhysical network interfaces (addresses omitted):\n'
    for path in /sys/class/net/*; do
        [ -e "$path/device" ] || continue
        iface="${path##*/}"
        printf '%s' "$iface"
        for name in operstate carrier speed; do
            value=$(cat "$path/$name" 2>/dev/null || true)
            printf ' %s=%s' "$name" "$value"
        done
        printf '\n'
    done
    printf '\nRelevant configuration:\n'
    for path in "$PERSIST_DIR/ugreen-leds.conf" /etc/ugreen-leds.conf; do
        printf '%s\n' "$path"
        grep -E '^(NETDEV_LED_NAMES|NETDEV_INTERFACE_NAMES|MAPPING_METHOD|BLINK_TYPE_POWER)=' "$path" 2>/dev/null || true
    done
    printf '\nInstalled ATA table:\n'
    grep -n 'ata_map=' "$PERSIST_DIR/scripts/ugreen-diskiomon" 2>/dev/null || true
    printf '\nService state:\n'
    # The report is public: status journal lines and journal prefixes carry the
    # hostname, and the disk monitor logs each serial under MAPPING_METHOD=serial.
    systemctl status --no-pager --full --lines=0 ugreen-probe-leds.service ugreen-diskiomon.service ugreen-netdevmon-multi.service ugreen-power-led.service 2>&1 || true
    printf '\nRecent LED service journal:\n'
    journalctl -b --no-pager -o cat -n 100 -u ugreen-probe-leds.service -u ugreen-diskiomon.service -u ugreen-netdevmon-multi.service -u ugreen-power-led.service 2>&1 | grep -v '^serial ' || true
}

idx_test_backup() {
    local path name unit state kernel units recovery_module=""
    local -a paths=()
    kernel=$(uname -r)
    mkdir -p "$IDX_TEST_DIR/backup"
    : > "$IDX_TEST_DIR/backup/absent.txt"
    : > "$IDX_TEST_DIR/backup/active.txt"
    : > "$IDX_TEST_DIR/backup/enabled.txt"
    : > "$IDX_TEST_DIR/backup/module-args.txt"
    # Only installer-owned paths; do not archive arbitrary pool contents.
    for name in "${PERSIST_FILES[@]}"; do
        paths+=("$PERSIST_DIR/$name")
    done
    for name in "${HELPER_SCRIPTS[@]}"; do
        paths+=("$PERSIST_DIR/scripts/$name" "/usr/bin/$name")
    done
    paths+=(/etc/ugreen-leds.conf /etc/modules-load.d/ugreen-led.conf "/lib/modules/$kernel/extra/led-ugreen.ko")
    # Exits 1 when nothing matches, as on a first install; the loop names the units
    # that matter either way. list-unit-files never names legacy netdevmon@ instances.
    units=$({ systemctl list-unit-files --no-legend --plain 'ugreen-*.service'; systemctl list-units --plain --no-legend 'ugreen-*.service'; } || true)
    mapfile -t IDX_TEST_UNITS < <(printf '%s\n' "$units" | awk 'NF {print $1}')
    for path in /etc/systemd/system/multi-user.target.wants/ugreen-netdevmon@*.service; do
        IDX_TEST_UNITS+=("${path##*/}")
    done
    for unit in ugreen-probe-leds.service ugreen-diskiomon.service ugreen-netdevmon-multi.service ugreen-power-led.service ugreen-netdevmon@.service "${IDX_TEST_UNITS[@]}"; do
        [[ "$unit" =~ ^ugreen-[a-zA-Z0-9@_.:-]+\.service$ ]] || continue
        paths+=("/etc/systemd/system/$unit" "/etc/systemd/system/multi-user.target.wants/$unit")
        if systemctl is-active --quiet "$unit"; then
            printf '%s\n' "$unit" >> "$IDX_TEST_DIR/backup/active.txt"
        fi
        state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        printf '%s %s\n' "$unit" "$state" >> "$IDX_TEST_DIR/backup/enabled.txt"
    done
    if [ -d /sys/module/led_ugreen ]; then
        recovery_module="$PERSIST_DIR/led-ugreen.ko"
        if [ ! -f "$recovery_module" ]; then
            recovery_module=$(modinfo -n led-ugreen)
            case "$recovery_module" in
                /lib/modules/*|/usr/lib/modules/*) ;;
                *) echo 'Cannot locate an old module for recovery; stopping before changes.' >&2; return 1 ;;
            esac
        fi
        [ -f "$recovery_module" ] || { echo 'Old module file is missing; cannot back it up.' >&2; return 1; }
        if [ "$(modinfo -F vermagic "$recovery_module" | awk '{print $1}')" != "$kernel" ]; then
            echo 'Old module cannot be verified for the running kernel; stopping before changes.' >&2
            return 1
        fi
        paths+=("$recovery_module")
        printf '%s\n' "$recovery_module" > "$IDX_TEST_DIR/backup/module-path"
    fi
    local -a existing=()
    for path in "${paths[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            existing+=("${path#/}")
        else
            printf '%s\n' "$path" >> "$IDX_TEST_DIR/backup/absent.txt"
        fi
    done
    # An empty archive is valid for a first installation.
    tar -cpf "$IDX_TEST_DIR/backup/files.tar" -C / --files-from /dev/null -- "${existing[@]}"
    tar -tf "$IDX_TEST_DIR/backup/files.tar" > "$IDX_TEST_DIR/backup/manifest.txt"
    if [ -d /sys/module/led_ugreen ]; then
        touch "$IDX_TEST_DIR/backup/module-was-loaded"
        for name in write_protocol num_netdev_leds num_disk_leds; do
            path="/sys/module/led_ugreen/parameters/$name"
            if [ -r "$path" ]; then
                printf '%s=%s\n' "$name" "$(cat "$path")" >> "$IDX_TEST_DIR/backup/module-args.txt"
            fi
        done
    fi
    printf '%s\n' "$kernel" > "$IDX_TEST_DIR/backup/kernel"
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'RUN_DIR=%q\nPERSIST_DIR=%q\n' "$IDX_TEST_DIR" "$PERSIST_DIR"
        cat <<'ROLLBACK'
if [ "${EUID}" -ne 0 ]; then echo 'Run this recovery script with sudo bash.'; exit 1; fi
[ "$(uname -r)" = "$(cat "$RUN_DIR/backup/kernel")" ] || { echo 'Kernel changed; stop and ask the maintainer.'; exit 1; }
# A failed test may never have reached the installer's writable-mount setup.
# Prepare protected restore destinations before stopping the current services.
remounted=()
trap 'for ((i = ${#remounted[@]} - 1; i >= 0; i--)); do mount -o remount,ro "${remounted[$i]}" || echo "Warning: could not make ${remounted[$i]} read-only again."; done' EXIT
for restore_path in /usr /etc "/lib/modules/$(uname -r)"; do
    # A stacked mount prints one line per layer; the last is the one remount acts on.
    mount_target=$(findmnt -n -o TARGET --target "$restore_path" | tail -n 1)
    mount_options=$(findmnt -n -o OPTIONS --target "$restore_path" | tail -n 1)
    case ",$mount_options," in
        *,ro,*)
            mount -o remount,rw "$mount_target" && remounted+=("$mount_target")
            mount_options=$(findmnt -n -o OPTIONS --target "$restore_path" | tail -n 1)
            case ",$mount_options," in
                *,ro,*)
                    # shortcut: backed-up files on a read-only path refuse even if unchanged, compare them with the archive if that gets reported.
                    if grep -q "^${restore_path#/}/" "$RUN_DIR/backup/manifest.txt"; then
                        echo "Cannot make $mount_target writable for recovery."
                        exit 1
                    fi
                    echo "Warning: $mount_target stays read-only; no backed-up file lives under $restore_path."
                    ;;
            esac
            ;;
    esac
done
unit_listing=$(systemctl list-units --state=active --plain --no-legend 'ugreen-*.service')
mapfile -t units < <(printf '%s\n' "$unit_listing" | awk 'NF {print $1}')
rm -f "$RUN_DIR/rolled-back"
for unit in "${units[@]}"; do systemctl stop "$unit"; done
if [ -d /sys/module/led_ugreen ] && ! rmmod led-ugreen; then
    # A failed test stopped its monitors before this script ran; only active.txt names those.
    for unit in "${units[@]}"; do systemctl start "$unit" || true; done
    while IFS= read -r unit; do systemctl start "$unit" || true; done < "$RUN_DIR/backup/active.txt"
    echo 'Module is busy; monitors restarted, nothing restored. Stop what uses led-ugreen or reboot, then rerun.'
    exit 1
fi
# Restore only the recorded installer-owned files, including the old disk patch.
while IFS= read -r path; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || rm -f -- "$path" || echo "Warning: could not remove $path."
done < "$RUN_DIR/backup/absent.txt"
tar -xpf "$RUN_DIR/backup/files.tar" -C /
rmdir -- "$PERSIST_DIR/scripts" 2>/dev/null || true
# The restored marker must not adopt the beta checkout. A copy, so a rerun still finds the clone.
rm -rf -- "$PERSIST_DIR/ugreen_leds_controller" "$PERSIST_DIR/.ugreen_leds_controller.swap-new" "$PERSIST_DIR/.ugreen_leds_controller.swap-old"
if [ -d "$RUN_DIR/backup/ugreen_leds_controller" ]; then
    cp -a -- "$RUN_DIR/backup/ugreen_leds_controller" "$PERSIST_DIR/"
fi
depmod -a || echo 'Warning: depmod failed; expected on a read-only /lib/modules.'
systemctl daemon-reload
while read -r unit state; do
    case "$state" in
        enabled) systemctl enable "$unit" ;;
        enabled-runtime) systemctl enable --runtime "$unit" ;;
        disabled|not-found|'') systemctl disable "$unit" 2>/dev/null || true ;;
    esac
done < "$RUN_DIR/backup/enabled.txt"
if [ -f "$RUN_DIR/backup/module-was-loaded" ]; then
    mapfile -t args < "$RUN_DIR/backup/module-args.txt"
    modprobe -a i2c-dev ledtrig-oneshot ledtrig-netdev
    module_path=$(cat "$RUN_DIR/backup/module-path")
    insmod "$module_path" "${args[@]}"
fi
while IFS= read -r unit; do systemctl start "$unit"; done < "$RUN_DIR/backup/active.txt"
touch "$RUN_DIR/rolled-back"
echo 'Previous LED installation restored. Check the LEDs and services.'
echo 'TrueNAS Init/Shutdown entries were not changed by the test.'
ROLLBACK
    } > "$IDX_TEST_DIR/rollback.sh.tmp"
    bash -n "$IDX_TEST_DIR/rollback.sh.tmp"
    chmod 700 "$IDX_TEST_DIR/rollback.sh.tmp"
    # Rollback puts this back: a machine must not lose its offline clone to a test.
    # Before the script exists, because it deletes the clone and across datasets this mv can fail.
    if [ -e "$PERSIST_DIR/ugreen_leds_controller" ]; then
        mv -- "$PERSIST_DIR/ugreen_leds_controller" "$IDX_TEST_DIR/backup/ugreen_leds_controller"
    fi
    mv -- "$IDX_TEST_DIR/rollback.sh.tmp" "$IDX_TEST_DIR/rollback.sh"
}

idx_test_prepare_install() {
    local unit units config="$PERSIST_DIR/ugreen-leds.conf"
    units=$(systemctl list-units --state=active --plain --no-legend 'ugreen-*.service')
    mapfile -t IDX_TEST_UNITS < <(printf '%s\n' "$units" | awk 'NF {print $1}')
    for unit in "${IDX_TEST_UNITS[@]}"; do systemctl stop "$unit"; done
    if [ -d /sys/module/led_ugreen ]; then rmmod led-ugreen; fi
    echo 'Old LED module confirmed absent before beta installation.'
    mkdir -p "$PERSIST_DIR"
    if [ ! -f "$config" ] && [ -f /etc/ugreen-leds.conf ]; then
        cp -a /etc/ugreen-leds.conf "$config"
    fi
    if [ -f "$config" ]; then
        # Preserve unrelated options. Old LED/interface overrides can obscure a
        # clean beta test; backups contain the original configuration verbatim.
        sed -E '/^[[:space:]]*(export[[:space:]]+)?NETDEV_(LED_NAMES|INTERFACE_NAMES)[[:space:]]*=/d' "$config" > "$config.idx-test"
        printf '\nNETDEV_LED_NAMES=""\nNETDEV_INTERFACE_NAMES=""\n' >> "$config.idx-test"
        if [ "$SYSTEM_PRODUCT_NAME" = iDX6011 ]; then
            sed -i -E '/^[[:space:]]*(export[[:space:]]+)?MAPPING_METHOD[[:space:]]*=/d' "$config.idx-test"
            printf 'MAPPING_METHOD=ata\n' >> "$config.idx-test"
        fi
        chmod --reference="$config" "$config.idx-test"
        mv -- "$config.idx-test" "$config"
    fi
    # Force both sources to refresh without --force (which discards config).
    rm -f -- "$PERSIST_DIR/.module-source" "$PERSIST_DIR/.installer-source"
}

# Explicitly load the validated cached image for the test. A modprobe lookup
# alone cannot identify the resident binary when srcversion is unavailable.
idx_test_load_cached_module() {
    local units unit
    local -a args=(write_protocol=smbus-block)
    units=$(systemctl list-units --state=active --plain --no-legend 'ugreen-*.service')
    mapfile -t IDX_TEST_UNITS < <(printf '%s\n' "$units" | awk 'NF {print $1}')
    for unit in "${IDX_TEST_UNITS[@]}"; do systemctl stop "$unit"; done
    if [ -d /sys/module/led_ugreen ]; then rmmod led-ugreen; fi
    if [ "$SYSTEM_PRODUCT_NAME" = 'iDX6011 Pro' ]; then
        args+=(num_netdev_leds=2 num_disk_leds=6)
    fi
    modprobe -a i2c-dev ledtrig-oneshot ledtrig-netdev
    sha256sum "$PERSIST_DIR/led-ugreen.ko"
    insmod "$PERSIST_DIR/led-ugreen.ko" "${args[@]}"
    echo "Loaded the test binary directly from $PERSIST_DIR/led-ugreen.ko"
    systemctl restart ugreen-probe-leds.service
    systemctl restart ugreen-diskiomon.service ugreen-netdevmon-multi.service ugreen-power-led.service
}

idx_test_verify() {
    local name cached loaded source
    source=$(cat "$PERSIST_DIR/.module-source")
    [ "$source" = "${IDX_MODULE_SOURCE}" ] || { echo 'Unexpected module source.'; return 1; }
    [ -d /sys/module/led_ugreen ] || { echo 'LED module is not loaded.'; return 1; }
    [ "$(cat /sys/module/led_ugreen/parameters/write_protocol)" = smbus-block ] || { echo 'Wrong loaded protocol.'; return 1; }
    [ "$(modinfo -F vermagic "$PERSIST_DIR/led-ugreen.ko" | awk '{print $1}')" = "$(uname -r)" ] || { echo 'Kernel/module mismatch.'; return 1; }
    cached=$(modinfo -F srcversion "$PERSIST_DIR/led-ugreen.ko" 2>/dev/null || true)
    loaded=$(cat /sys/module/led_ugreen/srcversion 2>/dev/null || true)
    if [ -n "$cached" ] && [ -n "$loaded" ] && [ "$cached" != "$loaded" ]; then
        echo 'Loaded binary does not match the cached module.'; return 1
    fi
    for name in num_netdev_leds num_disk_leds; do
        [ -r "/sys/module/led_ugreen/parameters/$name" ] || { echo "Missing module parameter: $name"; return 1; }
    done
    if [ "$SYSTEM_PRODUCT_NAME" = 'iDX6011 Pro' ]; then
        if [ "$(cat /sys/module/led_ugreen/parameters/num_netdev_leds)" != 2 ] ||
           [ "$(cat /sys/module/led_ugreen/parameters/num_disk_leds)" != 6 ]; then
            echo 'Pro parameters not applied.'; return 1
        fi
        [ -d /sys/class/leds/netdev2 ] || { echo 'Pro netdev2 missing.'; return 1; }
    fi
    for name in power netdev disk1 disk2 disk3 disk4 disk5 disk6; do
        [ -d "/sys/class/leds/$name" ] || { echo "LED missing: $name"; return 1; }
    done
    for name in ugreen-probe-leds.service ugreen-diskiomon.service ugreen-netdevmon-multi.service ugreen-power-led.service; do
        systemctl is-active --quiet "$name" || { echo "Service not active: $name"; return 1; }
    done
}

idx_test_finish() {
    local status="$1" report storage
    trap - EXIT
    set +e
    if [ "$IDX_TEST_MODE" = install ]; then
        idx_test_capture > "$IDX_TEST_DIR/after.txt" 2>&1
    fi
    storage=$(dirname "$PERSIST_DIR")
    [ "$storage/" != /mnt/ ] || storage=$PERSIST_DIR
    if report=$(
        printf '# UGREEN iDX hardware feedback\n\nStage: %s\n' "$IDX_TEST_MODE"
        printf 'Technical result: %s (exit %s)\n' "$IDX_TEST_RESULT" "$status"
        printf '\nPlease complete before posting in issue #23:\n'
        printf -- '- Commercial model printed on device/box: ...\n- Power LED correct / boot animation stopped: ...\n- LAN LED(s) correspond to the connected port(s): ...\n- Disk LEDs correspond to bays 1–6; empty bays stay off: ...\n- Unexpected LEDs, errors or other observations: ...\n- Reboot tested: not tested\n'
        printf '\nPhysical LED mapping is NOT verified automatically.\n'
        printf '\n## Before\n```text\n'; cat "$IDX_TEST_DIR/before.txt"; printf '\n```\n'
        if [ -f "$IDX_TEST_DIR/after.txt" ]; then
            printf '\n## After\n```text\n'; cat "$IDX_TEST_DIR/after.txt"; printf '\n```\n'
        fi
        if [ -f "$IDX_TEST_DIR/install.log" ]; then
            printf '\n## Installer and verification (last 160 lines)\n```text\n'
            tail -n 160 "$IDX_TEST_DIR/install.log"; printf '\n```\n'
        fi
    ) && report=${report//"$storage"/<storage>} && report=${report//"$IDX_TEST_INSTALLED"/<storage>} &&
        printf '%s\n' "$report" | sed -E 's#/mnt/[^[:space:]]+#<storage>#g' > "$IDX_TEST_DIR/feedback.md"; then
        :
    else
        status=1
        echo "ERROR: Could not write the complete feedback report at $IDX_TEST_DIR/feedback.md" >&2
    fi
    printf '\n==================================================\n'
    if [ "$status" -eq 0 ] && [ "$IDX_TEST_RESULT" = 'TECHNICAL PASS' ]; then
        echo 'SUCCESS: beta module and required LED services passed the technical checks.'
        echo 'Now check the physical power, LAN and disk LEDs. Their mapping still needs your feedback.'
    elif [ "$status" -eq 0 ]; then
        echo 'Information collected. No installation, module or service changes were made.'
        echo 'Send this report before proceeding to the installation test.'
    else
        echo 'FAILED: the beta test did not complete successfully. Do not report it as working.'
    fi
    printf 'Feedback file: %s/feedback.md\n' "$IDX_TEST_DIR"
    printf 'Show report: sudo cat %q\n' "$IDX_TEST_DIR/feedback.md"
    echo 'Paste its contents into your comment in issue #23 and fill in the observation lines.'
    echo 'https://github.com/0x556c79/install_ugreen_leds_controller/issues/23'
    if [ -f "$IDX_TEST_DIR/rollback.sh" ]; then
        printf 'Backup: %s/backup\nRecovery command: sudo bash %q\n' "$IDX_TEST_DIR" "$IDX_TEST_DIR/rollback.sh"
        echo 'No reboot is required for this test. TrueNAS Init/Shutdown entries were not changed.'
    fi
    exit "$status"
}

run_idx_test() {
    local script earlier
    idx_test_find_persist_dir
    SYSTEM_PRODUCT_NAME=$(read_system_product_name)
    if [ "$IDX_TEST_MODE" = install ] && [ "$SYSTEM_PRODUCT_NAME" != iDX6011 ] && [ "$SYSTEM_PRODUCT_NAME" != 'iDX6011 Pro' ]; then
        echo 'The installation test requires exact DMI iDX6011 or iDX6011 Pro; use collect for other DMI values.' >&2
        return 1
    fi
    # A second backup would capture the first test's changes, not the original install.
    if [ "$IDX_TEST_MODE" = install ]; then
        for earlier in "$(dirname "$PERSIST_DIR")"/ugreen-idx-test-*/rollback.sh; do
            if [ -f "$earlier" ] && [ ! -e "${earlier%/*}/rolled-back" ]; then
                printf 'An earlier test was not rolled back. Run this first: sudo bash %q\nDelete its folder instead only if that rollback already ran, or that test passed and you keep the beta: it holds the only copy of your previous install.\n' "$earlier" >&2
                return 1
            fi
        done
    fi
    if [ "$DRY_RUN" = true ]; then
        printf 'DRY RUN: would run iDX stage %s using %s; no report, backup or system changes made.\n' "$IDX_TEST_MODE" "$PERSIST_DIR"
        return 0
    fi
    umask 077
    IDX_TEST_DIR=$(mktemp -d "$(dirname "$PERSIST_DIR")/ugreen-idx-test-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    IDX_TEST_RESULT='FAILED'
    # An off-pool install is not under the storage folder, and systemctl status prints its path.
    IDX_TEST_INSTALLED=$(find_installed_persist_dir)
    trap 'idx_test_finish "$?"' EXIT
    idx_test_capture > "$IDX_TEST_DIR/before.txt" 2>&1
    if [ "$IDX_TEST_MODE" = collect ]; then
        IDX_TEST_RESULT='INFORMATION COLLECTED; INSTALLATION NOT TESTED'
        return 0
    fi
    # Backup must succeed before config, cache, modules or services are changed.
    idx_test_backup > "$IDX_TEST_DIR/install.log" 2>&1
    script=$(readlink -f "$0")
    idx_test_prepare_install >> "$IDX_TEST_DIR/install.log" 2>&1
    printf 'Backup saved. If this session ends, recover with: sudo bash %q\nInstalling the upstream beta; please wait...\n' "$IDX_TEST_DIR/rollback.sh"
    if bash "$script" --controller-source idx6011 --persist-dir "$PERSIST_DIR" --yes >> "$IDX_TEST_DIR/install.log" 2>&1; then
        idx_test_load_cached_module >> "$IDX_TEST_DIR/install.log" 2>&1
        # Give short-lived monitor startup failures time to surface.
        sleep 2
        if idx_test_verify >> "$IDX_TEST_DIR/install.log" 2>&1; then
            IDX_TEST_RESULT='TECHNICAL PASS'
        else
            return 1
        fi
    else
        return 1
    fi
}

if [ -n "$IDX_TEST_MODE" ]; then
    run_idx_test
    exit 0
fi

select_controller_profile


# ============================================================================
# Persistent Directory Determination
# ============================================================================

determine_persistent_directory() {
    local persist_base=""
    local installed_dir=""
    local path_error=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local current_dir_name
    current_dir_name="$(basename "$script_dir")"

    # Priority 1: --persist-dir explicitly specified
    if [ -n "${PERSIST_DIR}" ]; then
        persist_base="${PERSIST_DIR}"
        log "Using explicitly specified persistent directory: ${persist_base}"
    # Priority 2: --pool-path specified
    elif [ -n "${POOL_PATH}" ]; then
        if [[ "${POOL_PATH}" != /mnt/* ]]; then
            persist_base="/mnt/${POOL_PATH}"
        else
            persist_base="${POOL_PATH}"
        fi
        persist_base="${persist_base}/leds_controller"
        log "Using pool path for persistent directory: ${persist_base}"
    # Uninstall only: the installed service knows the real folder
    elif [ "${UNINSTALL}" = "true" ] && installed_dir=$(find_installed_persist_dir) && [ -n "${installed_dir}" ]; then
        persist_base="${installed_dir}"
        log "Found persistent directory from the installed service: ${persist_base}"
    # Priority 3: Script is already in a directory named "leds_controller"
    elif [ "$current_dir_name" = "leds_controller" ]; then
        persist_base="$script_dir"
        log "Script is located in 'leds_controller' directory, using it: ${persist_base}"
    # Priority 4: Check if "leds_controller" exists at the same level as script
    elif [ -d "${script_dir}/leds_controller" ]; then
        persist_base="${script_dir}/leds_controller"
        log "Found existing 'leds_controller' directory at same level: ${persist_base}"
    # Priority 5: --use-current-dir specified
    elif [ "${USE_CURRENT_DIR}" = "true" ]; then
        persist_base="${INSTALL_DIR}/leds_controller"
        log "Using current directory for persistent storage: ${persist_base}"
    # Priority 6: Interactive selection (unless --yes or --uninstall is set)
    else
        if [ "${AUTO_YES}" = "true" ] || [ "${UNINSTALL}" = "true" ]; then
            # Non-interactive default; uninstall reports it later if it does not exist
            persist_base="${script_dir}/leds_controller"
            log "Using leds_controller at script directory level: ${persist_base}"
        else
            echo ""
            echo "=========================================="
            echo "Persistent Storage Directory Selection"
            echo "=========================================="
            echo "The installer needs a writable location to store:"
            echo "  - Kernel module (led-ugreen.ko)"
            echo "  - Helper scripts"
            echo "  - Installer copy for reuse"
            echo ""
            echo "Script location: ${script_dir}"
            echo "Current directory: ${INSTALL_DIR}"
            echo ""
            echo "Choose an option:"
            echo "  1) Create 'leds_controller/' at script directory level (${script_dir})"
            echo "  2) Create 'leds_controller/' in current directory (${INSTALL_DIR})"
            echo "  3) Specify a custom path"
            echo ""
            read -r -p "Enter choice (1, 2, or 3): " choice

            case "$choice" in
                1)
                    persist_base="${script_dir}/leds_controller"
                    log "Selected: script directory level - ${persist_base}"
                    ;;
                2)
                    persist_base="${INSTALL_DIR}/leds_controller"
                    log "Selected: current directory - ${persist_base}"
                    ;;
                3)
                    read -r -p "Enter full path: " custom_path
                    custom_path="${custom_path#"${custom_path%%[![:space:]]*}"}"
                    custom_path="${custom_path%"${custom_path##*[![:space:]]}"}"

                    if [ -z "$custom_path" ]; then
                        echo "Error: empty path provided" >&2
                        exit 1
                    fi

                    if [[ "$custom_path" != */leds_controller ]]; then
                        persist_base="${custom_path}/leds_controller"
                    else
                        persist_base="$custom_path"
                    fi
                    log "Selected: custom path - ${persist_base}"
                    ;;
                *)
                    echo "Error: invalid choice" >&2
                    exit 1
                    ;;
            esac
        fi
    fi

    persist_base=$(realpath -m -- "$persist_base")

    # Uninstall writes no paths and must still reach old off-pool installs.
    if [ "${UNINSTALL}" != "true" ]; then
        path_error=$(persist_path_problem "$persist_base")
        if [ -n "$path_error" ]; then
            if [ "${DRY_RUN}" = "true" ]; then
                log "WARNING: persistent directory ${persist_base} ${path_error}; a real install would stop here"
            else
                echo "Error: persistent directory ${persist_base} ${path_error}." >&2
                exit 1
            fi
        fi
    fi

    # Validate the path is writable
    if [ "${UNINSTALL}" = "true" ]; then
        log "Uninstall will use persistent directory: ${persist_base}"
    elif [ "${DRY_RUN}" != "true" ]; then
        if [ -d "$persist_base" ]; then
            if [ ! -w "$persist_base" ]; then
                echo "Error: directory exists but is not writable: ${persist_base}" >&2
                exit 1
            fi
            log "Persistent directory exists and is writable: ${persist_base}"
        else
            if ! mkdir -p "$persist_base" 2>/dev/null; then
                echo "Error: cannot create persistent directory: ${persist_base}" >&2
                exit 1
            fi
            log "Created persistent directory: ${persist_base}"
        fi
    else
        log "DRY RUN: would validate/create persistent directory: ${persist_base}"
    fi

    PERSIST_DIR="${persist_base}"
}

determine_persistent_directory

# main's auto put these models on the fork, and stable cannot drive them.
if [ "${CONTROLLER_SOURCE}" = "auto" ] && [ "${CONTROLLER_PROFILE}" = "upstream" ] &&
    [[ "${SYSTEM_PRODUCT_NAME}" == *iDX601[12]* ]] &&
    [[ "$(cat "${PERSIST_DIR}/.module-source" 2>/dev/null)" == idx6011:* ]]; then
    CONTROLLER_SOURCE="idx6011"
    select_controller_profile
fi

# Set the clone directory - under persistent directory
CLONE_DIR="${PERSIST_DIR}/ugreen_leds_controller"
# Deleted without asking, so the names must not be ones a person would keep work under.
CLONE_NEW="${PERSIST_DIR}/.ugreen_leds_controller.swap-new"
CLONE_OLD="${PERSIST_DIR}/.ugreen_leds_controller.swap-old"

# Only these prove an install; the other file names could be the user's own.
# v2.0.x wrote no marker, so there only its version file with its module, or the installed unit, can tell.
has_install_marker() {
    [ -f "${PERSIST_DIR}/.installer-source" ] || [ -f "${PERSIST_DIR}/.module-source" ] ||
        { [ -f "${PERSIST_DIR}/.version" ] && [ -f "${PERSIST_DIR}/led-ugreen.ko" ]; } ||
        [ "$(find_installed_persist_dir)" = "${PERSIST_DIR}" ]
}

if [ "${UNINSTALL}" != "true" ] && [ "${FORCE}" != "true" ] && [ -e "${CLONE_DIR}" ] && ! has_install_marker; then
    if [ "${DRY_RUN}" = "true" ]; then
        log "WARNING: ${CLONE_DIR} was not created by this installer; a real install would stop here"
    else
        echo "Error: ${CLONE_DIR} exists, but ${PERSIST_DIR} holds no installation." >&2
        echo "It may be your own work. Move it, or use --force to replace it (this also resets the LED configuration)." >&2
        exit 1
    fi
fi

# ============================================================================
# Read-Only Filesystem Detection
# ============================================================================

# Get TrueNAS version from system
OS_VERSION=""
if [ -r "/etc/version" ]; then
    OS_VERSION=$(sed -n 's/^\([0-9]\{1,\}\.[0-9]\{1,\}\(\.[0-9]\{1,\}\)*\).*/\1/p' /etc/version | head -1 || true)
fi

check_and_remount_readonly() {
    local mount_point="$1"
    local mount_opts

    # A stacked mount prints one line per layer; the last is the one remount acts on.
    mount_opts=$(mount | grep " on ${mount_point} " | tail -n 1 | awk '{print $6}' | tr -d '()' || echo "")

    # Match 'ro' as a distinct comma-separated mount option (avoids matching 'proc', 'errors=remount-ro', etc.)
    if echo ",${mount_opts}," | grep -q ',ro,'; then
        log "Detected read-only filesystem at ${mount_point}"
        if [ "${DRY_RUN}" = "true" ]; then
            log "DRY RUN: would remount ${mount_point} read-write"
            # It remains read-only; preview the conservative persistent-file path.
            return 1
        fi
        if mount -o remount,rw "${mount_point}" 2>/dev/null; then
            REMOUNTED_RW+=("${mount_point}")
            log "Successfully remounted ${mount_point} as read-write"
            return 0
        else
            log "Cannot remount ${mount_point} as read-write"
            return 1
        fi
    else
        return 0
    fi
}

prepare_writable_system() {
    # Detect read-only root
    if ! check_and_remount_readonly "/usr" 2>/dev/null; then
        READONLY_ROOT=true
        log "Read-only root filesystem detected - /usr cannot be changed"
    fi

    # Try to remount /etc as writable
    if [ -n "${OS_VERSION}" ]; then
        BOOT_POOL_PATH="boot-pool/ROOT/${OS_VERSION}"
        if [ -d "/${BOOT_POOL_PATH}/etc" ]; then
            check_and_remount_readonly "/${BOOT_POOL_PATH}/etc" 2>/dev/null || true
        else
            log "Boot pool path /${BOOT_POOL_PATH}/etc not found, skipping /etc remount"
        fi
    else
        log "No OS version from /etc/version, skipping /etc remount"
    fi
}

# ============================================================================
# Uninstall Logic
# ============================================================================

# A failed removal must not stop the rest of the cleanup.
uninstall_remove() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would remove $1"
    elif rm -rf -- "$1"; then
        log "Removed $1"
    else
        log "Warning: could not remove $1"
        UNINSTALL_LEFT+=("$1")
    fi
}

uninstall_all() {
    local kernel_ver unit_dir
    kernel_ver=$(uname -r)
    unit_dir=$(find_installed_persist_dir)
    # Step 2 removes the unit, so ask now.
    local owned=false
    if [ -d "${PERSIST_DIR}" ] && has_install_marker; then
        owned=true
    elif [ -n "${unit_dir}" ] && [ "${unit_dir}" != "${PERSIST_DIR}" ]; then
        # Going on would remove the only proof the real folder may have.
        echo "Error: ${PERSIST_DIR} holds no installation; the installed service uses ${unit_dir}." >&2
        echo "Rerun with --persist-dir \"${unit_dir}\"." >&2
        exit 1
    fi

    echo ""
    echo "=========================================="
    echo "Uninstalling UGREEN LEDs Controller"
    echo "=========================================="
    echo ""
    echo "Persistent directory: ${PERSIST_DIR}"
    echo ""

    prepare_writable_system

    # --- Step 1: Stop and disable systemd services ---
    log "Stopping and disabling systemd services..."

    local services_to_stop=("ugreen-diskiomon.service" "ugreen-power-led.service" "ugreen-netdevmon-multi.service" "ugreen-probe-leds.service")

    # Find any leftover ugreen-netdevmon@*.service instances
    for svc in /etc/systemd/system/multi-user.target.wants/ugreen-netdevmon@*.service; do
        if [ -e "$svc" ]; then
            services_to_stop+=("${svc##*/}")
        fi
    done

    for svc in "${services_to_stop[@]}"; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null || systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            if [ "${DRY_RUN}" = "true" ]; then
                log "DRY RUN: would stop and disable ${svc}"
            else
                systemctl stop "${svc}" 2>/dev/null || true
                systemctl disable "${svc}" 2>/dev/null || true
                log "Stopped and disabled ${svc}"
            fi
        else
            log "Service ${svc} not found, skipping"
        fi
    done

    # --- Step 2: Remove systemd service files ---
    log "Removing systemd service files..."
    local service_files=("ugreen-diskiomon.service" "ugreen-netdevmon-multi.service" "ugreen-netdevmon@.service" "ugreen-power-led.service" "ugreen-probe-leds.service")
    for svc_file in "${service_files[@]}"; do
        uninstall_remove "/etc/systemd/system/${svc_file}"
    done

    # --- Step 3: Reload systemd daemon ---
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would reload systemd daemon"
    else
        if systemctl daemon-reload; then
            log "Reloaded systemd daemon"
        else
            log "Warning: systemctl daemon-reload failed"
            UNINSTALL_LEFT+=("systemd state of the removed units (daemon-reload failed)")
        fi
    fi

    # --- Step 4: Unload kernel modules ---
    log "Unloading kernel modules..."
    local modules_to_unload=("led-ugreen" "ledtrig-netdev" "ledtrig-oneshot" "i2c-dev")
    for mod in "${modules_to_unload[@]}"; do
        if [ -d "/sys/module/${mod//-/_}" ]; then
            if [ "${DRY_RUN}" = "true" ]; then
                log "DRY RUN: would unload module ${mod}"
            else
                if rmmod "${mod}" 2>/dev/null; then
                    log "Unloaded module ${mod}"
                else
                    log "Warning: could not unload module ${mod} (may be in use by other subsystems)"
                    if [ "${mod}" = "led-ugreen" ]; then
                        UNINSTALL_LEFT+=("led-ugreen module (still loaded)")
                    fi
                fi
            fi
        else
            log "Module ${mod} not loaded, skipping"
        fi
    done

    # --- Step 5: Remove module autoload configuration ---
    uninstall_remove "/etc/modules-load.d/ugreen-led.conf"

    # --- Step 6: Remove kernel module from system directory ---
    uninstall_remove "/lib/modules/${kernel_ver}/extra/led-ugreen.ko"

    # --- Step 7: Remove scripts from /usr/bin ---
    log "Removing scripts from /usr/bin..."
    for script in "${HELPER_SCRIPTS[@]}"; do
        uninstall_remove "/usr/bin/${script}"
    done

    # --- Step 8: Remove system configuration ---
    uninstall_remove "/etc/ugreen-leds.conf"

    # --- Step 9: Remove installer-owned files; the folder may be shared ---
    local persist_found=true
    local remove_persist=true
    local name
    if [ -d "${PERSIST_DIR}" ]; then
        if [ "${owned}" != "true" ]; then
            log "${PERSIST_DIR} holds no installation, leaving everything in it alone"
            UNINSTALL_LEFT+=("${PERSIST_DIR} (holds no installation, nothing removed)")
            remove_persist=false
        elif [ "${AUTO_YES}" != "true" ] && [ "${DRY_RUN}" != "true" ]; then
            echo ""
            echo "=========================================="
            echo "WARNING: About to delete installer files"
            echo "=========================================="
            echo ""
            echo "This will permanently remove from ${PERSIST_DIR}:"
            echo "  kernel module, helper scripts, LED configuration, version markers,"
            echo "  installer copy and the cloned controller repository."
            echo ""
            echo "Other files stay; the folder itself is removed only if nothing else is in it."
            echo ""
            read -r -p "Delete these installer files? (y/n): " confirm || confirm=n
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                log "Skipped persistent directory cleanup (user declined)"
                UNINSTALL_LEFT+=("${PERSIST_DIR} (kept at your request)")
                remove_persist=false
            fi
        fi

        if [ "${remove_persist}" = "true" ]; then
            if [ -L "${PERSIST_DIR}/scripts" ]; then
                log "${PERSIST_DIR}/scripts is a symlink, not following it"
                UNINSTALL_LEFT+=("${PERSIST_DIR}/scripts (symlink)")
            else
                for name in "${HELPER_SCRIPTS[@]}"; do
                    uninstall_remove "${PERSIST_DIR}/scripts/${name}"
                done
            fi
            uninstall_remove "${CLONE_NEW}"
            uninstall_remove "${CLONE_OLD}"
            # Renamed away first, so a killed removal never leaves a half tree the next run would trust.
            if [ "${DRY_RUN}" != "true" ] && [ ! -e "${CLONE_OLD}" ] && mv "${CLONE_DIR}" "${CLONE_OLD}" 2>/dev/null; then
                uninstall_remove "${CLONE_OLD}"
            fi
            uninstall_remove "${CLONE_DIR}"
            for name in "${PERSIST_DIR}"/.led-ugreen.ko.download.*; do
                uninstall_remove "${name}"
            done
            for name in "${PERSIST_FILES[@]}"; do
                uninstall_remove "${PERSIST_DIR}/${name}"
            done

            if [ "${DRY_RUN}" = "true" ]; then
                log "DRY RUN: would remove ${PERSIST_DIR} if nothing else is in it"
            else
                rmdir -- "${PERSIST_DIR}/scripts" 2>/dev/null || true
                rmdir -- "${PERSIST_DIR}" 2>/dev/null || true
                if [ -d "${PERSIST_DIR}" ]; then
                    log "Kept ${PERSIST_DIR}: it still holds other files or is a mount point"
                else
                    log "Removed persistent directory ${PERSIST_DIR}"
                fi
            fi
        fi
    else
        log "Persistent directory ${PERSIST_DIR} not found, skipping"
        persist_found=false
    fi

    echo ""
    echo "=========================================="
    if [ "${DRY_RUN}" = "true" ]; then
        echo "Uninstall Dry Run Complete!"
        echo "=========================================="
        echo ""
        echo "No changes were made. Review the actions above."
        echo "Run without --dry-run to perform the actual uninstall."
    elif [ "${#UNINSTALL_LEFT[@]}" -gt 0 ]; then
        echo "Uninstall Finished With Items Left"
        echo "=========================================="
        echo ""
        echo "These items were left in place:"
        printf '  %s\n' "${UNINSTALL_LEFT[@]}"
    else
        echo "Uninstall Complete!"
        echo "=========================================="
        echo ""
        if [ "${persist_found}" = "true" ]; then
            echo "All UGREEN LEDs controller components have been removed."
        fi
        echo "A reboot is recommended to ensure a clean state."
    fi
    if [ "${persist_found}" = "false" ]; then
        echo ""
        echo "No persistent directory was found at ${PERSIST_DIR}."
        echo "If you installed elsewhere, rerun with --persist-dir <path> to remove those files."
    fi
    echo ""
}

# Early exit for uninstall mode (no internet access needed)
if [ "${UNINSTALL}" = "true" ]; then
    uninstall_all
    exit 0
fi

# ============================================================================
# Version Detection
# ============================================================================

if [ -z "${TRUENAS_VERSION}" ]; then
    TRUENAS_VERSION="${OS_VERSION}"
fi

if [ -z "${TRUENAS_VERSION}" ]; then
    echo "Failed to detect TrueNAS version from /etc/version." >&2
    echo "Use -v <version> when running outside TrueNAS SCALE." >&2
    exit 1
fi

log_separator
log "Detected TrueNAS version: ${TRUENAS_VERSION}"

# Function to find the codename for the current version by checking GitHub directories
find_codename_for_version() {
    local version="$1"
    local found_codename=""

    log "Searching for codename matching version ${version}..." >&2

    # Iterate through each codename directory from KMOD_DIRS
    while IFS= read -r dir_name; do
        if [ -z "$dir_name" ]; then
            continue
        fi

        # Use GitHub API to check if this codename directory contains our version
        local check_api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/${BUILD_PATH}/${dir_name}/${version}?ref=${ARTIFACT_REF}"

        if curl --silent --fail --connect-timeout 10 --max-time 30 "${check_api_url}" > /dev/null 2>&1; then
            found_codename="$dir_name"
            log "Found matching codename: ${dir_name}" >&2
            break
        fi
    done <<< "$KMOD_DIRS"

    # If not found via GitHub, try hardcoded fallback
    if [ -z "$found_codename" ]; then
        log "Could not find codename via GitHub, trying fallback mapping..." >&2
        local version_series
        version_series=$(echo "$version" | cut -d'.' -f1,2)

        case "$version_series" in
            "24.10") found_codename="TrueNAS-SCALE-ElectricEel" ;;
            "24.04") found_codename="TrueNAS-SCALE-Dragonfish" ;;
            "25.04") found_codename="TrueNAS-SCALE-Fangtooth" ;;
            "25.10") found_codename="TrueNAS-SCALE-Goldeye" ;;
            *)
                echo "Unsupported TrueNAS SCALE version: ${version}." >&2
                echo "No precompiled kernel module found in repository." >&2
                echo "Please build the kernel module manually." >&2
                exit 1
                ;;
        esac

        log "Using fallback codename: ${found_codename}" >&2
    fi

    echo "$found_codename"
}

log_separator

# ============================================================================
# Module URL Probing and Fallback Resolution
# ============================================================================

# Probes whether a pre-built module URL is reachable.
# Returns: 0=available (HTTP 200), 1=not found (HTTP 404), 2=transient/network error
probe_module_url() {
    local url="$1"
    local http_code
    http_code=$(curl --silent --location --head \
        --write-out '%{http_code}' \
        --output /dev/null \
        --connect-timeout 10 --max-time 30 \
        "${url}" 2>/dev/null) || http_code="000"
    case "$http_code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   return 2 ;;
    esac
}

# Returns: 0=available, 1=not found. Stops the install if the network still fails
# after one retry: only a real 404 proves a module is missing.
probe_candidate_url() {
    local url="$1"
    local probe_result=0

    probe_module_url "$url" || probe_result=$?
    if [ "$probe_result" -eq 2 ]; then
        log "Transient error for ${url}, retrying..."
        probe_result=0
        probe_module_url "$url" || probe_result=$?
    fi
    if [ "$probe_result" -eq 2 ]; then
        echo "Network error while checking ${url}." >&2
        echo "Cannot tell whether this kernel module exists; check the connection and rerun." >&2
        exit 1
    fi
    return "$probe_result"
}

# Resolves the best available pre-built module URL starting from running_version,
# then decrementing the patch component (third dot-field) within the same YY.MM train.
# Never crosses major boundaries (e.g. 25.04 never falls back to 24.10).
# On success: updates global MODULE_URL. If a fallback is used, also emits a warning block.
# On total failure: prints an error and exits.
resolve_module_url() {
    local running_version="$1"
    local codename="$2"
    local version_major
    local version_patch_str
    local version_patch
    local candidate_url

    version_major=$(echo "$running_version" | cut -d. -f1,2)
    version_patch_str=$(echo "$running_version" | cut -d. -f3)

    if [ "${CONTROLLER_PROFILE}" = "idx6011" ]; then
        candidate_url="${REPO_URL}/${codename}/${running_version}/led-ugreen.ko"
        log "Probing exact experimental module: ${candidate_url}"

        if probe_candidate_url "$candidate_url"; then
            MODULE_URL="$candidate_url"
            return 0
        fi

        echo "Exact upstream ${IDX_UPSTREAM_TAG} kernel module not found for TrueNAS SCALE ${running_version}." >&2
        echo "The experimental iDX6011 Pro profile does not use older-version or third-party fallbacks." >&2
        echo "Tagged artifacts currently cover the 25.04 and 25.10 release trains:" >&2
        echo "  https://github.com/${REPO_OWNER}/${REPO_NAME}/tree/${ARTIFACT_REF}/${BUILD_PATH}" >&2
        exit 1
    fi

    # Build ordered candidate list: exact running version, then descending patch variants
    local -a candidates
    candidates=("$running_version")

    if [[ "$version_patch_str" =~ ^[0-9]+$ ]]; then
        version_patch=$(( 10#$version_patch_str ))
        # For 4-part versions (e.g. 25.04.0.1), also try the 3-part form
        local three_part="${version_major}.${version_patch}"
        if [ "$three_part" != "$running_version" ]; then
            candidates+=("$three_part")
        fi
        local p
        p=$(( version_patch - 1 ))
        while [ "$p" -ge 0 ]; do
            candidates+=("${version_major}.${p}")
            p=$(( p - 1 ))
        done
    fi
    # If patch is non-numeric, candidates contains only running_version (no fallback)

    for candidate in "${candidates[@]}"; do
        candidate_url="${REPO_URL}/${codename}/${candidate}/led-ugreen.ko"
        log "Probing module availability: ${candidate_url}"

        if probe_candidate_url "$candidate_url"; then
            MODULE_URL="$candidate_url"
            if [ "$candidate" != "$running_version" ]; then
                echo ""
                echo "=========================================="
                echo "WARNING: Using fallback kernel module"
                echo "=========================================="
                echo ""
                echo "  WARNING: Kernel sources for TrueNAS SCALE ${running_version} are unavailable."
                echo "           Falling back to sources from ${candidate}."
                echo "           The kernel module will be built against an older minor release;"
                echo "           if the kernel ABI has changed, the module may not load correctly."
                echo ""
                log "Using fallback module for ${candidate} (running TrueNAS ${running_version})"
            fi
            return 0
        fi
    done

    # All candidates exhausted: prints an error and exits
    echo "Kernel module not found for TrueNAS SCALE ${running_version}."
    echo "No fallback module available within the ${version_major} release train."
    echo "Please build the kernel module manually."
    exit 1
}

# ============================================================================
# Version Tracking and Smart Download Logic
# ============================================================================

check_version_and_download() {
    local stored_version
    local stored_source

    stored_version=$(cat "${PERSIST_DIR}/.version" 2>/dev/null || true)
    stored_source=$(cat "${PERSIST_DIR}/.module-source" 2>/dev/null || true)

    if [ "${stored_version}" != "${TRUENAS_VERSION}" ]; then
        log "TrueNAS version changed (${stored_version:-<none>} -> ${TRUENAS_VERSION})"
    elif [ "${stored_source}" != "${CONTROLLER_MODULE_SOURCE}" ]; then
        log "Controller source changed (${stored_source:-<none>} -> ${CONTROLLER_MODULE_SOURCE})"
    elif [ -f "${PERSIST_DIR}/led-ugreen.ko" ]; then
        log "Kernel module already up to date for version ${TRUENAS_VERSION} and source ${CONTROLLER_PROFILE}"
        return 0
    else
        log "Kernel module file missing, will download"
    fi

    # A failed update must not keep this boot's install down. Their Requires= starts the probe service.
    if [ "${DRY_RUN}" != "true" ] && [ "${stored_version}" = "${TRUENAS_VERSION}" ] && [ -f "${PERSIST_DIR}/led-ugreen.ko" ]; then
        PREVIOUSLY_ACTIVE_LED_SERVICES=(ugreen-diskiomon.service ugreen-netdevmon-multi.service ugreen-power-led.service)
    fi
    fetch_truenas_versions
    TRUENAS_NAME=$(find_codename_for_version "${TRUENAS_VERSION}")
    log "Verifying kernel module availability..."
    resolve_module_url "${TRUENAS_VERSION}" "${TRUENAS_NAME}"
    NEED_MODULE_DOWNLOAD=true
}

# A killed swap left the old module here; the markers still describe that one.
if [ "${DRY_RUN}" != "true" ] && [ -f "${PERSIST_DIR}/led-ugreen.ko.previous" ]; then
    mv -f "${PERSIST_DIR}/led-ugreen.ko.previous" "${PERSIST_DIR}/led-ugreen.ko"
fi

check_version_and_download

# ============================================================================
# Self-Copy Mechanism
# ============================================================================

copy_installer_to_persistent_dir() {
    local script_path
    script_path="$(readlink -f "$0")"
    local persist_script="${PERSIST_DIR}/install_ugreen_leds_controller.sh"

    if [ "${script_path}" != "${persist_script}" ]; then
        log "Copying installer to ${persist_script} for future reuse"
        if [ "${DRY_RUN}" = "true" ]; then
            log "DRY RUN: would copy ${script_path} to ${persist_script}"
        else
            cp "${script_path}" "${persist_script}" || log "Warning: failed to copy installer"
            chmod +x "${persist_script}" || true
        fi
    else
        log "Installer already running from persistent directory"
    fi
}

copy_installer_to_persistent_dir

# ============================================================================
# Clone Repository
# ============================================================================

log_separator
log "Preparing repository..."

# True when this run can finish on the files already installed.
clone_is_optional() {
    local script
    [ "${NEED_MODULE_DOWNLOAD}" = "false" ] || return 1
    [ "${FORCE}" = "false" ] || return 1
    [ -f /etc/systemd/system/ugreen-diskiomon.service ] || return 1
    for script in "${HELPER_SCRIPTS[@]}"; do
        [ -f "${PERSIST_DIR}/scripts/${script}" ] || return 1
    done
}

abort_clone() {
    rm -rf "${CLONE_NEW}"
    if clone_is_optional; then
        log "Warning: $1 Continuing with the installed files; the next run tries again"
        return 0
    fi
    echo "$1" >&2
    echo "Any existing repository in ${CLONE_DIR} was left untouched." >&2
    exit 1
}

clone_controller_repository() {
    local clone_marker_file="${PERSIST_DIR}/.installer-source"
    local stored_clone_source
    local needs_clone=false
    local actual_commit=""

    stored_clone_source=$(cat "${clone_marker_file}" 2>/dev/null || true)

    if [ ! -d "${CLONE_DIR}/.git" ]; then
        needs_clone=true
    elif [ "${FORCE}" = "true" ]; then
        log "FORCE: re-cloning repository"
        needs_clone=true
    elif [ "${NEED_MODULE_DOWNLOAD}" = "true" ]; then
        log "Module changes in this run, refreshing repository"
        needs_clone=true
    elif [ "${stored_clone_source}" != "${SCRIPT_SOURCE_MARKER}" ]; then
        log "Repository source changed (${stored_clone_source:-<none>} -> ${SCRIPT_SOURCE_MARKER})"
        needs_clone=true
    fi

    if [ "${needs_clone}" = "true" ]; then
        log "Cloning controller scripts from ${SCRIPT_REPO_URL} (${SCRIPT_REPO_REF})..."
        if [ "${DRY_RUN}" = "true" ]; then
            log "DRY RUN: would clone repository to ${CLONE_DIR}"
            return 0
        fi

        rm -rf "${CLONE_NEW}" "${CLONE_OLD}"
        if ! git clone --branch "${SCRIPT_REPO_BRANCH}" --single-branch "${SCRIPT_REPO_URL}" "${CLONE_NEW}" -q; then
            abort_clone "Cloning ${SCRIPT_REPO_URL} failed."
            return 0
        fi
        if [ "${SCRIPT_REPO_REF}" != "${SCRIPT_REPO_BRANCH}" ] && ! git -C "${CLONE_NEW}" checkout --detach "${SCRIPT_REPO_REF}" -q; then
            abort_clone "Checking out ${SCRIPT_REPO_REF} failed."
            return 0
        fi

        if [ -n "${SCRIPT_EXPECTED_COMMIT}" ]; then
            actual_commit=$(git -C "${CLONE_NEW}" rev-parse HEAD || true)
            if [ "${actual_commit}" != "${SCRIPT_EXPECTED_COMMIT}" ]; then
                abort_clone "Controller script source verification failed. Expected ${SCRIPT_EXPECTED_COMMIT}, got ${actual_commit}."
                return 0
            fi
            log "Verified controller scripts at ${actual_commit}"
        fi

        # A run killed between the renames leaves a missing clone, handled like any other.
        if [ -e "${CLONE_DIR}" ]; then
            mv "${CLONE_DIR}" "${CLONE_OLD}"
        fi
        echo "${SCRIPT_SOURCE_MARKER}" > "${clone_marker_file}"
        mv "${CLONE_NEW}" "${CLONE_DIR}"
        rm -rf "${CLONE_OLD}"
        log "Repository cloned successfully"
    else
        log "Repository already present in ${CLONE_DIR}"
    fi
}

patch_config_template() {
    local config_path="${CLONE_DIR}/scripts/ugreen-leds.conf"

    if [ ! -f "${config_path}" ]; then
        return 0
    fi

    if grep -q '^NETDEV_LED_NAMES=' "${config_path}" 2>/dev/null; then
        return 0
    fi

    log "Adding network LED override options to ${config_path}"
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would update ${config_path}"
        return 0
    fi

    cat <<'EOL' >> "${config_path}"

# Optional network LED override.
# Leave empty to auto-detect: netdev on legacy models, netdev/netdev2 on iDX6011 Pro.
# The legacy iDX names network_stat/network_stat2 are translated during migration.
NETDEV_LED_NAMES=""

# Optional network interface override. Leave empty to use detected physical interfaces.
NETDEV_INTERFACE_NAMES=""
EOL
}

clone_controller_repository
patch_config_template

# ============================================================================
# Kernel Module Installation
# ============================================================================

log_separator
log "Installing kernel module..."

validate_downloaded_module() {
    local module_file="$1"
    local module_info
    local module_kernel
    local running_kernel
    local required_parameter

    if [ ! -s "${module_file}" ]; then
        echo "Downloaded kernel module is empty." >&2
        return 1
    fi

    if ! module_info=$(modinfo "${module_file}" 2>&1); then
        echo "Downloaded file is not a valid kernel module:" >&2
        echo "${module_info}" >&2
        return 1
    fi

    if [ "${CONTROLLER_PROFILE}" = "idx6011" ]; then
        for required_parameter in write_protocol num_netdev_leds num_disk_leds; do
            if ! grep -Eq "^parm:[[:space:]]+${required_parameter}:" <<< "${module_info}"; then
                echo "Downloaded module is missing required ${IDX_UPSTREAM_TAG} parameter: ${required_parameter}" >&2
                return 1
            fi
        done

        module_kernel=$(modinfo -F vermagic "${module_file}" 2>/dev/null | awk '{print $1}')
        running_kernel=$(uname -r)
        if [ "${module_kernel}" != "${running_kernel}" ]; then
            echo "Downloaded module kernel mismatch: expected ${running_kernel}, got ${module_kernel}." >&2
            return 1
        fi
    fi

    return 0
}

install_kernel_module() {
    local module_dest="${PERSIST_DIR}/led-ugreen.ko"
    local module_download=""
    local kernel_ver
    kernel_ver=$(uname -r)

    if [ "${NEED_MODULE_DOWNLOAD}" = "true" ]; then
        log "Downloading kernel module to persistent directory..."
        log "Module URL: ${MODULE_URL}"
        if [ "${DRY_RUN}" = "true" ]; then
            log "DRY RUN: would download, validate, and atomically install module at ${module_dest}"
        else
            # A killed download leaves its temp file behind.
            rm -f -- "${PERSIST_DIR}"/.led-ugreen.ko.download.*
            # modinfo reads a path as a module file only when the name ends in .ko.
            module_download=$(mktemp --suffix=.ko "${PERSIST_DIR}/.led-ugreen.ko.download.XXXXXX")
            if ! curl --fail --silent --show-error --location \
                --connect-timeout 10 --max-time 120 \
                --output "${module_download}" "${MODULE_URL}"; then
                rm -f "${module_download}"
                echo "Kernel module download failed." >&2
                exit 1
            fi

            if ! validate_downloaded_module "${module_download}"; then
                rm -f "${module_download}"
                echo "Kernel module validation failed; the existing cached module was left untouched." >&2
                exit 1
            fi

            chmod 644 "${module_download}"
            if [ -f "${module_dest}" ]; then
                mv -f "${module_dest}" "${module_dest}.previous"
                MODULE_SWAP_ACTIVE=true
            fi
            mv -f "${module_download}" "${module_dest}"
            log "Kernel module downloaded and validated successfully"
        fi
    else
        log "Kernel module download skipped (already up to date)"
    fi

    # Not earlier: a kill cannot restore read-only /usr, and the steps above can run for minutes.
    prepare_writable_system

    # For writable systems, also copy to standard location and run depmod
    if [ "${READONLY_ROOT}" = "false" ]; then
        if [ "${DRY_RUN}" = "true" ]; then
            log "DRY RUN: would also copy to /lib/modules/${kernel_ver}/extra/ and run depmod"
        else
            mkdir -p "/lib/modules/${kernel_ver}/extra" 2>/dev/null || true
            if cp "${module_dest}" "/lib/modules/${kernel_ver}/extra/led-ugreen.ko" 2>/dev/null; then
                log "Copied kernel module to /lib/modules/${kernel_ver}/extra/"
                # Register with modprobe so 'modprobe led-ugreen' works at boot
                if depmod -a 2>/dev/null; then
                    log "depmod completed — led-ugreen module registered with modprobe"
                else
                    log "Warning: depmod failed; module may not be auto-loadable via modprobe"
                fi
            else
                log "Note: could not copy to /lib/modules (read-only filesystem)"
            fi
        fi
    fi
}

# ============================================================================
# Module Loading Configuration
# ============================================================================

PREVIOUS_MODULE_ARGS=()
MODULE_UNLOADED=false

stop_led_services_for_module_reload() {
    local service
    local services=(
        ugreen-diskiomon.service
        ugreen-netdevmon-multi.service
        ugreen-power-led.service
        ugreen-probe-leds.service
    )

    MODULE_SWAP_ACTIVE=true
    PREVIOUSLY_ACTIVE_LED_SERVICES=()
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            PREVIOUSLY_ACTIVE_LED_SERVICES+=("${service}")
            log "Stopping ${service} before replacing the led-ugreen module"
            systemctl stop "${service}" || true
        fi
    done
}

unload_led_module() {
    local name
    for name in write_protocol num_netdev_leds num_disk_leds; do
        if [ -r "/sys/module/led_ugreen/parameters/${name}" ]; then
            PREVIOUS_MODULE_ARGS+=("${name}=$(cat "/sys/module/led_ugreen/parameters/${name}")")
        fi
    done
    if ! rmmod led-ugreen; then
        echo "Unable to unload the existing led-ugreen module; restoring previously active services." >&2
        exit 1
    fi
    MODULE_LOADED=false
    MODULE_UNLOADED=true
}

# Puts the module from before this run back, running with its old arguments.
restore_previous_module() {
    local module="${PERSIST_DIR}/led-ugreen.ko"
    local installed
    installed="/lib/modules/$(uname -r)/extra/led-ugreen.ko"
    if [ -f "${module}.previous" ]; then
        mv -f "${module}.previous" "${module}"
        # The beta probe tries modprobe first, so the rejected module must not stay there.
        [ ! -f "${installed}" ] || cp -f "${module}" "${installed}" 2>/dev/null
    elif [ "${MODULE_UNLOADED}" = "false" ]; then
        return 1
    fi
    # Still true means the old module never left memory.
    [ "${MODULE_LOADED}" = "false" ] || return 0
    if [ -d /sys/module/led_ugreen ] && ! rmmod led-ugreen 2>/dev/null; then
        return 0
    fi
    # The beta needs model parameters. With no old arguments, loading stays with the probe.
    # The marker still describes the restored module; this run may be a switch to stable.
    if { [ "${CONTROLLER_PROFILE}" = "idx6011" ] || [[ "$(cat "${PERSIST_DIR}/.module-source" 2>/dev/null)" == idx6011:* ]]; } &&
        [ "${MODULE_UNLOADED}" = "false" ]; then
        return 0
    fi
    insmod "${module}" "${PREVIOUS_MODULE_ARGS[@]}" || log "Warning: could not reload the previous led-ugreen module"
}

# A new module with no older one to return to is not trusted: the next run downloads again.
# A run that downloaded nothing keeps .version, so the next offline boot can still start.
# shortcut: a cached module that later breaks stays until .version is deleted by hand, re-download it when that gets reported.
module_load_failed() {
    if [ ! -f "${PERSIST_DIR}/led-ugreen.ko.previous" ] && [ "${NEED_MODULE_DOWNLOAD}" = "true" ]; then
        rm -f "${PERSIST_DIR}/.version"
    fi
    echo "ERROR: $1" >&2
    exit 1
}

# Markers move only once the new module runs, so a failed swap is retried by the next run.
commit_module_markers() {
    MODULE_SWAP_ACTIVE=false
    rm -f "${PERSIST_DIR}/led-ugreen.ko.previous"
    [ "${NEED_MODULE_DOWNLOAD}" = "true" ] || return 0

    # Update version file
    echo "${TRUENAS_VERSION}" > "${PERSIST_DIR}/.version"
    echo "${CONTROLLER_MODULE_SOURCE}" > "${PERSIST_DIR}/.module-source"
    log "Updated version tracker to ${TRUENAS_VERSION}"
    log "Updated module source tracker to ${CONTROLLER_PROFILE}"
}

beta_module_parameters_match() {
    local parameters=/sys/module/led_ugreen/parameters

    case "${SYSTEM_PRODUCT_NAME}" in
        "DXP4800 GT"|"iDX6011"|"iDX6012")
            [ "$(cat "${parameters}/write_protocol" 2>/dev/null)" = "smbus-block" ]
            ;;
        "iDX6011 Pro")
            [ "$(cat "${parameters}/write_protocol" 2>/dev/null)" = "smbus-block" ] &&
                [ "$(cat "${parameters}/num_netdev_leds" 2>/dev/null)" = "2" ] &&
                [ "$(cat "${parameters}/num_disk_leds" 2>/dev/null)" = "6" ]
            ;;
    esac
}

# Check if led-ugreen is already loaded via sysfs (more reliable than lsmod which may not be in PATH)
# Kernel normalizes dashes to underscores, so the module dir is /sys/module/led_ugreen
MODULE_LOADED=false
if [ -d "/sys/module/led_ugreen" ]; then
    MODULE_LOADED=true
fi

install_kernel_module

log_separator
log "Configuring kernel module loading..."
if [ "${DRY_RUN}" = "true" ]; then
    if [ "${CONTROLLER_PROFILE}" = "idx6011" ]; then
        log "DRY RUN: would configure dependency modules only; ugreen-probe-leds will load led-ugreen with ${IDX_UPSTREAM_TAG} parameters"
    else
        log "DRY RUN: would create /etc/modules-load.d/ugreen-led.conf with led-ugreen"
    fi
else
    {
        echo "i2c-dev"
        if [ "${CONTROLLER_PROFILE}" = "upstream" ]; then
            echo "led-ugreen"
        fi
        echo "ledtrig-oneshot"
        echo "ledtrig-netdev"
    } > /etc/modules-load.d/ugreen-led.conf
    chmod 644 /etc/modules-load.d/ugreen-led.conf
fi

log "Loading kernel modules..."
if [ "${DRY_RUN}" = "true" ]; then
    log "DRY RUN: would load kernel modules"
else
    modprobe -a i2c-dev ledtrig-oneshot ledtrig-netdev || true

    if [ "${CONTROLLER_PROFILE}" = "idx6011" ]; then
        BETA_MODULE_RELOAD_REQUIRED=false
        if [ "${NEED_MODULE_DOWNLOAD}" = "true" ]; then
            BETA_MODULE_RELOAD_REQUIRED=true
        elif [ "${MODULE_LOADED}" = "true" ] && ! beta_module_parameters_match; then
            log "Loaded beta module parameters do not match the detected model"
            BETA_MODULE_RELOAD_REQUIRED=true
        fi

        if [ "${BETA_MODULE_RELOAD_REQUIRED}" = "true" ]; then
            stop_led_services_for_module_reload
            if [ "${MODULE_LOADED}" = "true" ]; then
                log "Unloading the previous led-ugreen module before upstream probe configuration"
                unload_led_module
            fi
        fi

        log "Deferring led-ugreen loading to ugreen-probe-leds so model parameters are preserved"
    elif [ "${MODULE_LOADED}" = "true" ] && [ "${NEED_MODULE_DOWNLOAD}" = "false" ]; then
        # Module already loaded and no new version downloaded — nothing to do
        log "Module led-ugreen already loaded and up to date, skipping"
    else
        if [ "${MODULE_LOADED}" = "true" ]; then
            # New version downloaded — unload old module before loading new one
            log "New module version downloaded, reloading led-ugreen..."
            stop_led_services_for_module_reload
            unload_led_module
        fi

        insmod "${PERSIST_DIR}/led-ugreen.ko" || module_load_failed "insmod could not load ${PERSIST_DIR}/led-ugreen.ko"
        commit_module_markers
    fi
fi

# ============================================================================
# Configuration File Setup
# ============================================================================

log_separator
log "Setting up configuration..."

CONFIG_FILE="${PERSIST_DIR}/ugreen-leds.conf"
TEMPLATE_CONFIG="${CLONE_DIR}/scripts/ugreen-leds.conf"

# Priority 1: Use existing config in persistent directory
if [ -f "$CONFIG_FILE" ] && [ "${FORCE}" != "true" ]; then
    log "Using existing configuration file at ${CONFIG_FILE}"
    echo ""
    echo "Note: Review ${TEMPLATE_CONFIG} for new options"
    echo ""

    if [ "${AUTO_YES}" != "true" ] && [ "${DRY_RUN}" != "true" ]; then
        read -r -p "Modify LED configuration now? (y/n): " MODIFY_CONF
        if [[ "$MODIFY_CONF" == "y" ]]; then
            nano "$CONFIG_FILE"
        fi
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would copy ${CONFIG_FILE} to /etc/ugreen-leds.conf"
    else
        cp "$CONFIG_FILE" /etc/ugreen-leds.conf
        log "Configuration copied to /etc/ugreen-leds.conf"
    fi
# Priority 2: Migrate existing /etc/ugreen-leds.conf to persistent directory
elif [ -f "/etc/ugreen-leds.conf" ] && [ "${FORCE}" != "true" ]; then
    log "Found existing configuration at /etc/ugreen-leds.conf"
    log "Migrating to persistent directory at ${CONFIG_FILE}"

    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would copy /etc/ugreen-leds.conf to ${CONFIG_FILE}"
    else
        cp /etc/ugreen-leds.conf "$CONFIG_FILE"
        log "Configuration migrated to ${CONFIG_FILE}"
    fi

    if [ "${AUTO_YES}" != "true" ] && [ "${DRY_RUN}" != "true" ]; then
        echo ""
        echo "Note: Review ${TEMPLATE_CONFIG} for new options"
        echo ""
        read -r -p "Modify LED configuration now? (y/n): " MODIFY_CONF
        if [[ "$MODIFY_CONF" == "y" ]]; then
            nano "$CONFIG_FILE"
            cp "$CONFIG_FILE" /etc/ugreen-leds.conf
        fi
    fi
# Priority 3: Use template for new installations
else
    log "No existing configuration found, using template"

    if [ "${AUTO_YES}" != "true" ] && [ "${DRY_RUN}" != "true" ]; then
        read -r -p "Modify LED configuration now? (y/n): " MODIFY_CONF
        if [[ "$MODIFY_CONF" == "y" ]]; then
            nano "$TEMPLATE_CONFIG"
        fi
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would copy template config to /etc/ugreen-leds.conf and ${CONFIG_FILE}"
    else
        cp "$TEMPLATE_CONFIG" /etc/ugreen-leds.conf
        cp "$TEMPLATE_CONFIG" "$CONFIG_FILE"
        chmod 644 /etc/ugreen-leds.conf
        log "Configuration saved to /etc/ugreen-leds.conf and ${CONFIG_FILE}"
    fi
fi

# ============================================================================
# Service Cleanup
# ============================================================================

check_and_remove_existing_services() {
    local service_name="ugreen-netdevmon"
    log "Checking for existing ${service_name} services..."

    # Remove any old single-interface netdevmon@ instances
    for service in "/etc/systemd/system/multi-user.target.wants/${service_name}@"*.service; do
        if [ -e "$service" ]; then
            log "Found legacy service ${service##*/}, removing"

            if [ "${DRY_RUN}" != "true" ]; then
                systemctl stop "${service##*/}" 2>/dev/null || true
                systemctl disable "${service##*/}" 2>/dev/null || true
                rm -f "$service" || true
                log "Removed ${service##*/}"
            fi
        fi
    done

    if [ "${DRY_RUN}" != "true" ]; then
        systemctl daemon-reload
    fi
}

check_and_remove_existing_services

# ============================================================================
# Scripts and Services Installation
# ============================================================================

# Patch ugreen-probe-leds to use insmod fallback instead of dkms (not available on TrueNAS)
# Args: $1 = script path, $2 = path to led-ugreen.ko
patch_probe_leds_script() {
    local script_path="$1"
    local ko_path="$2"

    if [ ! -f "${script_path}" ]; then
        return 0
    fi

    # Check if script still has the DKMS fallback block (upstream version)
    if ! grep -q 'dkms' "${script_path}" 2>/dev/null; then
        log "ugreen-probe-leds already patched or dkms block not present, skipping patch"
        return 0
    fi

    log "Patching ${script_path}: replacing DKMS fallback with insmod from ${ko_path}"

    # Replace everything from the DKMS fallback comment down to the closing 'fi'
    # using awk for portable multi-line replacement
    awk -v ko="${ko_path}" '
        /^model=\$\(dmidecode -s system-product-name 2>\/dev\/null \|\| true\)$/ {
            print "model=\"\""
            print "if [ -r /sys/class/dmi/id/product_name ]; then"
            print "    model=$(sed -n \0471p\047 /sys/class/dmi/id/product_name 2>/dev/null || true)"
            print "fi"
            print "if [ -z \"$model\" ] && command -v dmidecode >/dev/null 2>&1; then"
            print "    model=$(dmidecode -s system-product-name 2>/dev/null || true)"
            print "fi"
            next
        }
        /# modprobe failed/ { in_dkms=1 }
        in_dkms && /^    fi$/ {
            print "        # Fallback: load module directly from persistent path (TrueNAS: dkms not available)"
            print "        KO_PATH=\"" ko "\""
            print "        if [ -f \"$KO_PATH\" ]; then"
            print "            echo \"Module led-ugreen not found for kernel $(uname -r), loading from persistent path...\""
            print "            module_args=()"
            print "            if declare -p modprobe_args >/dev/null 2>&1; then"
            print "                module_args=(\"${modprobe_args[@]:1}\")"
            print "            fi"
            print "            insmod \"$KO_PATH\" \"${module_args[@]}\" || { echo \"ERROR: insmod failed for $KO_PATH\"; exit 1; }"
            print "            echo \"Module loaded successfully via insmod\""
            print "        else"
            print "            echo \"ERROR: led-ugreen.ko not found at $KO_PATH\""
            print "            echo \"Please reinstall using install_ugreen_leds_controller.sh\""
            print "            exit 1"
            print "        fi"
            print "    fi"
            in_dkms=0
            next
        }
        !in_dkms { print }
    ' "${script_path}" > "${script_path}.patched" && mv "${script_path}.patched" "${script_path}"
    chmod +x "${script_path}"
    log "Patched ${script_path} successfully"
}

# The non-Pro iDX6011 report verifies ATA ports, not HCTL or kernel LED IDs.
# Apply only to the explicit beta test on this exact DMI product.
patch_diskiomon_script() {
    local script_path="$1"
    if [ "${CONTROLLER_PROFILE}" != "idx6011" ] || [ "${SYSTEM_PRODUCT_NAME}" != "iDX6011" ]; then
        return 0
    fi
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would patch ${script_path} for iDX6011 ATA bay order"
        return 0
    fi
    if [ ! -f "${script_path}" ]; then
        echo "Missing disk monitor: ${script_path}" >&2
        return 1
    fi
    if [ "$(grep -c '^ata_map=(' "${script_path}")" != "1" ]; then
        echo "Unexpected upstream ATA map in ${script_path}; refusing to patch." >&2
        return 1
    fi
    sed 's/^ata_map=(.*)$/ata_map=("ata3" "ata4" "ata5" "ata6" "ata1" "ata2")/' \
        "${script_path}" > "${script_path}.patched"
    mv "${script_path}.patched" "${script_path}"
    chmod +x "${script_path}"
    log "Patched ${script_path}: exact iDX6011 ATA bay order (LED names unchanged)"
}

patch_netdevmon_multi_script() {
    local script_path="$1"

    if [ ! -f "${script_path}" ]; then
        return 0
    fi

    log "Patching ${script_path}: adding multi-LED iDX network support"
    cat <<'EOL' > "${script_path}"
#!/usr/bin/bash

# install_ugreen_leds_controller: supports upstream netdev/netdev2 and legacy network_stat LEDs.

if [[ -f /etc/ugreen-leds.conf ]]; then
    source /etc/ugreen-leds.conf
fi

NETDEV_BLINK_TX=${NETDEV_BLINK_TX:=1}
NETDEV_BLINK_RX=${NETDEV_BLINK_RX:=1}
NETDEV_BLINK_INTERVAL=${NETDEV_BLINK_INTERVAL:=200}
COLOR_NETDEV_NORMAL=${COLOR_NETDEV_NORMAL:="255 165 0"}
BRIGHTNESS_NETDEV_LED=${BRIGHTNESS_NETDEV_LED:=255}
CHECK_NETDEV_INTERVAL=${CHECK_NETDEV_INTERVAL:=60}
CHECK_LINK_SPEED=${CHECK_LINK_SPEED:=false}
CHECK_LINK_SPEED_DYNAMIC=${CHECK_LINK_SPEED_DYNAMIC:=false}

discover_leds() {
    if [[ -n "${NETDEV_LED_NAMES:-}" ]]; then
        local -a override_leds
        local override_led
        read -r -a override_leds <<< "${NETDEV_LED_NAMES}"

        # Migrate only the previously documented iDX override. Preserve every
        # other custom configuration exactly as the user supplied it.
        if [[ "${NETDEV_LED_NAMES}" == "network_stat network_stat2" \
            && -d /sys/class/leds/netdev && -d /sys/class/leds/netdev2 ]]; then
            echo "Migrating legacy network_stat/network_stat2 override to netdev/netdev2" >&2
            printf '%s\n' netdev netdev2
            return
        fi

        for override_led in "${override_leds[@]}"; do
            if [[ ! -d "/sys/class/leds/${override_led}" ]]; then
                echo "Configured network LED not found: ${override_led}" >&2
                return 1
            fi
        done
        printf '%s\n' "${override_leds[@]}"
        return
    fi

    if [[ -d /sys/class/leds/netdev ]]; then
        echo "netdev"
        local suffix
        for suffix in {2..9}; do
            [[ -d "/sys/class/leds/netdev${suffix}" ]] && echo "netdev${suffix}"
        done
        return
    fi

    # A failed beta swap restores the old fork's module, which uses these names.
    [[ -d /sys/class/leds/network_stat ]] && echo "network_stat"
    [[ -d /sys/class/leds/network_stat2 ]] && echo "network_stat2"
}

discover_interfaces() {
    if [[ -n "${NETDEV_INTERFACE_NAMES:-}" ]]; then
        local -a override_interfaces
        read -r -a override_interfaces <<< "${NETDEV_INTERFACE_NAMES}"
        printf '%s\n' "${override_interfaces[@]}"
        return
    fi

    for iface_path in /sys/class/net/*; do
        iface=$(basename "$iface_path")
        case "$iface" in
            lo|docker*|veth*|br*|vb*) continue ;;
        esac
        if [[ -e "$iface_path/device" ]]; then
            echo "$iface"
        fi
    done | sort
}

init_led() {
    local led="$1"

    if [[ ! -d "/sys/class/leds/${led}" ]]; then
        echo "Network LED not found at /sys/class/leds/$led"
        return 1
    fi

    modprobe ledtrig-netdev 2>/dev/null || true
    echo netdev > "/sys/class/leds/${led}/trigger" &&
        echo "$NETDEV_BLINK_TX" > "/sys/class/leds/${led}/tx" &&
        echo "$NETDEV_BLINK_RX" > "/sys/class/leds/${led}/rx" &&
        echo "$NETDEV_BLINK_INTERVAL" > "/sys/class/leds/${led}/interval" &&
        echo "$COLOR_NETDEV_NORMAL" > "/sys/class/leds/${led}/color" &&
        echo "$BRIGHTNESS_NETDEV_LED" > "/sys/class/leds/${led}/brightness"
}

set_speed_color() {
    local led="$1"
    local speed="$2"

    if [[ "$CHECK_LINK_SPEED_DYNAMIC" == "true" ]]; then
        local low_speed high_speed ratio r g b
        local -a low_color high_color
        low_speed=${CHECK_LINK_SPEED_DYNAMIC_SPEED_LOW:-0}
        high_speed=${CHECK_LINK_SPEED_DYNAMIC_SPEED_HIGH:-10000}
        read -r -a low_color <<< "${CHECK_LINK_SPEED_DYNAMIC_COLOR_LOW:-255 0 0}"
        read -r -a high_color <<< "${CHECK_LINK_SPEED_DYNAMIC_COLOR_HIGH:-0 255 0}"

        ratio=$(awk -v speed="$speed" -v low="$low_speed" -v high="$high_speed" \
            'BEGIN { if (high == low) print 1; else print (speed - low) / (high - low) }')
        ratio=$(awk -v r="$ratio" 'BEGIN {print (r < 0) ? 0 : (r > 1) ? 1 : r}')

        r=$(awk -v ratio="$ratio" -v low="${low_color[0]}" -v high="${high_color[0]}" \
            'BEGIN {printf "%.0f", low + ratio * (high - low)}')
        g=$(awk -v ratio="$ratio" -v low="${low_color[1]}" -v high="${high_color[1]}" \
            'BEGIN {printf "%.0f", low + ratio * (high - low)}')
        b=$(awk -v ratio="$ratio" -v low="${low_color[2]}" -v high="${high_color[2]}" \
            'BEGIN {printf "%.0f", low + ratio * (high - low)}')

        echo "$r $g $b" > "/sys/class/leds/${led}/color"
    elif [[ "$CHECK_LINK_SPEED" == "true" ]]; then
        case "$speed" in
            100)   echo "${COLOR_NETDEV_LINK_100:-0 255 0}" > "/sys/class/leds/${led}/color" ;;
            1000)  echo "${COLOR_NETDEV_LINK_1000:-0 0 255}" > "/sys/class/leds/${led}/color" ;;
            2500)  echo "${COLOR_NETDEV_LINK_2500:-255 255 0}" > "/sys/class/leds/${led}/color" ;;
            10000) echo "${COLOR_NETDEV_LINK_10000:-255 255 255}" > "/sys/class/leds/${led}/color" ;;
            *)     echo "$COLOR_NETDEV_NORMAL" > "/sys/class/leds/${led}/color" ;;
        esac
    else
        echo "$COLOR_NETDEV_NORMAL" > "/sys/class/leds/${led}/color"
    fi
}

bind_led_to_interface() {
    local led="$1"
    local iface="$2"
    local operstate speed link_state

    if [[ -z "$iface" ]]; then
        echo "" > "/sys/class/leds/${led}/device_name"
        echo 0 > "/sys/class/leds/${led}/link"
        return
    fi

    operstate=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "down")
    speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || echo "0")
    [[ "$speed" =~ ^[0-9]+$ ]] || speed=0

    if [[ "$operstate" == "up" ]]; then
        link_state=1
    else
        link_state=0
    fi

    echo "$iface" > "/sys/class/leds/${led}/device_name"
    echo "$link_state" > "/sys/class/leds/${led}/link"
    set_speed_color "$led" "$speed"
}

select_legacy_interface() {
    local active_iface=""
    local max_speed=0
    local operstate speed

    for iface in "$@"; do
        operstate=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "down")
        if [[ "$operstate" == "up" ]]; then
            speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || echo "0")
            [[ "$speed" =~ ^[0-9]+$ ]] || speed=0
            if [[ "$speed" -gt "$max_speed" ]]; then
                max_speed=$speed
                active_iface=$iface
            fi
        fi
    done

    echo "$active_iface"
}

mapfile -t leds < <(discover_leds)
if [[ ${#leds[@]} -eq 0 ]]; then
    echo "No network LEDs found"
    exit 1
fi

for led in "${leds[@]}"; do
    init_led "$led" || exit 1
done

echo "UGREEN multi-interface network monitor started"
echo "Network LEDs: ${leds[*]}"

while true; do
    mapfile -t interfaces < <(discover_interfaces)

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo "No physical ethernet interfaces found"
        sleep "$CHECK_NETDEV_INTERVAL"
        continue
    fi

    echo "Monitoring interfaces: ${interfaces[*]}"

    if [[ ${#leds[@]} -eq 1 ]]; then
        active_iface=$(select_legacy_interface "${interfaces[@]}")
        if [[ -n "$active_iface" ]]; then
            bind_led_to_interface "${leds[0]}" "$active_iface"
        else
            bind_led_to_interface "${leds[0]}" ""
        fi
    else
        for i in "${!leds[@]}"; do
            bind_led_to_interface "${leds[$i]}" "${interfaces[$i]:-}"
        done
    fi

    sleep "$CHECK_NETDEV_INTERVAL"
done
EOL
    chmod +x "${script_path}"
}

log_separator
log "Installing scripts and services..."

install_scripts_and_services() {
    # After a refresh that failed but was optional, the clone may hold another source.
    if [ ! -d "${CLONE_DIR}" ] || [ "$(cat "${PERSIST_DIR}/.installer-source" 2>/dev/null)" != "${SCRIPT_SOURCE_MARKER}" ]; then
        if [ "${DRY_RUN}" = "true" ]; then
            log "DRY RUN: repository not cloned yet; a real run would copy helper scripts, apply patches and install service files"
        else
            log "Repository not available; keeping the installed scripts and service files"
        fi
        return 0
    fi

    cd "${CLONE_DIR}"

    # Create scripts directory in persistent location
    local scripts_dest="${PERSIST_DIR}/scripts"
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would create ${scripts_dest}"
    else
        mkdir -p "${scripts_dest}"
    fi

    # Copy scripts
    for script in "${HELPER_SCRIPTS[@]}"; do
        if [ -f "scripts/${script}" ]; then
            if [ "${DRY_RUN}" = "true" ]; then
                log "DRY RUN: would copy scripts/${script} to ${scripts_dest}/"
            else
                cp "scripts/${script}" "${scripts_dest}/"
                chmod +x "${scripts_dest}/${script}"
            fi
        fi
    done

    patch_diskiomon_script "${scripts_dest}/ugreen-diskiomon"

    # Patch ugreen-probe-leds in persistent scripts dir to use insmod fallback
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would patch ${scripts_dest}/ugreen-probe-leds to use insmod fallback"
        log "DRY RUN: would patch ${scripts_dest}/ugreen-netdevmon-multi for iDX dual LAN LEDs"
    else
        patch_probe_leds_script "${scripts_dest}/ugreen-probe-leds" "${PERSIST_DIR}/led-ugreen.ko"
        patch_netdevmon_multi_script "${scripts_dest}/ugreen-netdevmon-multi"
    fi

    # Update and install service files
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would update and install service files"
    else
        for svc in scripts/systemd/*.service; do
            [ -e "${svc}" ] || continue
            local svc_name
            svc_name=$(basename "${svc}")

            # Update paths in service file; quoted so a storage path may contain spaces
            sed "s|/usr/bin/ugreen-\([^ ]*\)|\"${scripts_dest}/ugreen-\1\"|g" "${svc}" > "/etc/systemd/system/${svc_name}"
            chmod 644 "/etc/systemd/system/${svc_name}"
            log "Installed service: ${svc_name}"
        done
        systemctl daemon-reload
    fi
}

install_scripts_and_services

# ============================================================================
# Service Enablement
# ============================================================================

log_separator
log "Enabling and starting services..."

if [ "${CONTROLLER_PROFILE}" = "idx6011" ]; then
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would enable and restart ugreen-probe-leds.service before dependent monitors"
    else
        if ! systemctl enable ugreen-probe-leds.service || ! systemctl restart ugreen-probe-leds.service; then
            journalctl -u ugreen-probe-leds.service -n 50 --no-pager -o cat 2>/dev/null || true
            module_load_failed "ugreen-probe-leds.service failed; refusing to start dependent LED monitors."
        fi

        if [ ! -d /sys/module/led_ugreen ]; then
            module_load_failed "ugreen-probe-leds.service completed without loading led-ugreen."
        fi
        if ! beta_module_parameters_match; then
            module_load_failed "The upstream beta module was not loaded with the required parameters for ${SYSTEM_PRODUCT_NAME:-this model}."
        fi
        commit_module_markers
        log "ugreen-probe-leds.service completed with the expected beta module parameters"
    fi
fi

# The power LED service also applies the power LED color and brightness.
for service in ugreen-diskiomon.service ugreen-netdevmon-multi.service ugreen-power-led.service; do
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would enable/restart ${service}"
    else
        systemctl enable "${service}" || true
        systemctl restart "${service}" || true
    fi
done

# Only now, so a signal above still starts them. Their Requires= brought the probe service back.
PREVIOUSLY_ACTIVE_LED_SERVICES=()

# ============================================================================
# Completion
# ============================================================================
echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
# Service Status Summary
print_service_status() {
    local service="$1"
    local state
    local sub_state
    state=$(systemctl show -p ActiveState --value "${service}" 2>/dev/null)
    sub_state=$(systemctl show -p SubState --value "${service}" 2>/dev/null)

    if [ "${state}" = "active" ]; then
        printf "  \e[32m●\e[0m %-45s \e[2m%s (%s)\e[0m\n" "${service}" "${state}" "${sub_state}"
    elif [ "${state}" = "inactive" ]; then
        printf "  \e[2m●\e[0m %-45s \e[2m%s (%s)\e[0m\n" "${service}" "${state}" "${sub_state}"
    else
        printf "  \e[31m●\e[0m %-45s \e[2m%s (%s)\e[0m\n" "${service}" "${state}" "${sub_state}"
    fi
}

if [ "${DRY_RUN}" != "true" ]; then
    echo ""
    echo "Service Status:"
    print_service_status "ugreen-diskiomon.service"
    print_service_status "ugreen-netdevmon-multi.service"
    print_service_status "ugreen-power-led.service"
    print_service_status "ugreen-probe-leds.service"
fi
echo ""
echo "Persistent directory: ${PERSIST_DIR}"
echo "Configuration: /etc/ugreen-leds.conf"
log_separator
echo ""
echo "For TrueNAS Init/Shutdown Scripts, use:"
echo "===================================================================================="
INIT_COMMAND="/bin/bash \"${PERSIST_DIR}/install_ugreen_leds_controller.sh\" --yes"
if [ "${CONTROLLER_SOURCE}" != "auto" ]; then
    INIT_COMMAND+=" --controller-source ${CONTROLLER_SOURCE}"
fi
# Only a folder with this name is found again from the script's location.
if [ "$(basename "${PERSIST_DIR}")" != "leds_controller" ]; then
    INIT_COMMAND+=" --persist-dir \"${PERSIST_DIR}\""
fi
if [ "${TRUENAS_VERSION}" != "${OS_VERSION}" ]; then
    INIT_COMMAND+=" -v ${TRUENAS_VERSION}"
fi
echo "  ${INIT_COMMAND}"
echo "===================================================================================="
if [ "${TRUENAS_VERSION}" != "${OS_VERSION}" ]; then
    echo "Remove -v ${TRUENAS_VERSION} from this command after the next TrueNAS update."
fi
echo ""
echo "Reboot recommended to verify all services start correctly."
echo ""
