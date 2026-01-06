#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Cleanup function to remove the cloned repository (but NOT persistent directory)
cleanup() {
    if [ "${NO_CLEANUP:-false}" = "true" ]; then
        return 0
    fi

    echo "Cleaning up..."
    # Only remove cloned repo if we cloned it in this run
    if [ "${CLONED_REPO:-false}" = "true" ]; then
        if [ -n "${CLONE_DIR:-}" ] && [ -d "${CLONE_DIR}" ]; then
            rm -rf "${CLONE_DIR}"
            echo "Removed cloned repository at ${CLONE_DIR}"
        fi
    fi
    echo "Cleanup completed."
}

trap cleanup EXIT

help() {
    NO_CLEANUP=true
    echo "Installation helper for ugreen_leds_controller. Needs to be run as root"
    echo
    echo "Syntax: install_ugreen_leds_controller.sh [-h] [-v <version>] [options]"
    echo
    echo "Options:"
    echo "  -h                    Print this help"
    echo "  -v <version>          Use predefined TrueNAS version (format: X.Y.Z or X.Y.Z.W)"
    echo "                        If not specified, will be extracted from /etc/version"
    echo
    echo "  --persist-dir <path>  Specify custom persistent storage directory"
    echo "  --use-current-dir     Use current working directory for leds_controller/ folder"
    echo "  --pool-path <path>    Specify ZFS pool path under /mnt/ for persistent storage"
    echo
    echo "  --dry-run             Show actions without making changes"
    echo "  --yes                 Assume 'yes' to all prompts (non-interactive mode)"
    echo "  --force               Allow destructive actions (use with care)"
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
    echo "  sudo bash install_ugreen_leds_controller.sh --yes"
    echo
}

# Variables
REPO_URL="https://raw.githubusercontent.com/miskcoo/ugreen_leds_controller/refs/heads/gh-actions/build-scripts/truenas/build"
# Dynamically fetch available TrueNAS builds from GitHub
REPO_OWNER="miskcoo"
REPO_NAME="ugreen_leds_controller"
REPO_BRANCH="gh-actions"
BUILD_PATH="build-scripts/truenas/build"
API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/${BUILD_PATH}?ref=${REPO_BRANCH}"

echo "Fetching available TrueNAS versions from GitHub..."
KMOD_DIRS=$(curl -s "${API_URL}" | grep -oP '"name":\s*"\K(TrueNAS-SCALE-[^"]+)' || true)

KMOD_URLS=()
while IFS= read -r dir_name; do
    if [ -n "$dir_name" ]; then
        KMOD_URLS+=("https://github.com/${REPO_OWNER}/${REPO_NAME}/tree/${REPO_BRANCH}/${BUILD_PATH}/${dir_name}")
    fi
done <<< "$KMOD_DIRS"

# Fallback to hardcoded list if API fails
if [ ${#KMOD_URLS[@]} -eq 0 ]; then
    echo "Warning: Could not fetch versions from GitHub API, using fallback list"
    KMOD_URLS=(
        "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-ElectricEel"
        "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Dragonfish"
        "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Fangtooth"
        "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Goldeye"
    )
fi
TRUENAS_VERSION=""
PERSIST_DIR=""
USE_CURRENT_DIR=false
POOL_PATH=""
DRY_RUN=false
AUTO_YES=false
FORCE=false
READONLY_ROOT=false
NEED_MODULE_DOWNLOAD=false
CLONED_REPO=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            help
            exit 0
            ;;
        -v)
            TRUENAS_VERSION="$2"
            shift 2
            ;;
        --persist-dir)
            PERSIST_DIR="$2"
            shift 2
            ;;
        --use-current-dir)
            USE_CURRENT_DIR=true
            shift
            ;;
        --pool-path)
            POOL_PATH="$2"
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
        *)
            echo "Unknown option: $1" >&2
            help
            exit 1
            ;;
    esac
done

# Ensure script is run as root
if [ "${EUID:-0}" -ne 0 ]; then
    echo "Please run as root."
    exit 1
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


# ============================================================================
# Persistent Directory Determination
# ============================================================================

determine_persistent_directory() {
    local persist_base=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local current_dir_name
    current_dir_name="$(basename "$script_dir")"

    # First: Ensure we're running under /mnt/ (TrueNAS requirement)
    if [[ "$script_dir" != /mnt/* ]] && [[ "$INSTALL_DIR" != /mnt/* ]]; then
        if [ "${AUTO_YES}" != "true" ] && [ "${DRY_RUN}" != "true" ]; then
            echo ""
            echo "=========================================="
            echo "WARNING: Not running under /mnt/"
            echo "=========================================="
            echo "This script must be run from a location under /mnt/ (on a ZFS pool)"
            echo "to ensure persistence across reboots on TrueNAS Scale."
            echo ""
            echo "Current location: ${script_dir}"
            echo ""
            echo "Please move this script to a location under /mnt/ and run it again."
            exit 1
        elif [ "${DRY_RUN}" = "true" ]; then
            log "WARNING: Script not under /mnt/ - would normally abort here"
        fi
    fi

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
    # Priority 6: Interactive selection (unless --yes is set)
    else
        if [ "${AUTO_YES}" = "true" ]; then
            # In non-interactive mode, create at script directory level
            persist_base="${script_dir}/leds_controller"
            log "Non-interactive mode: using leds_controller at script directory level: ${persist_base}"
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

    # Validate the path is writable
    if [ "${DRY_RUN}" != "true" ]; then
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

# Set the clone directory - under persistent directory
CLONE_DIR="${PERSIST_DIR}/ugreen_leds_controller"

# ============================================================================
# Version Detection and Module URL Setup
# ============================================================================

# Get TrueNAS version from system
OS_VERSION=$(grep -oP '^[0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?' /etc/version || echo "")
if [ -z "${TRUENAS_VERSION}" ]; then
    TRUENAS_VERSION="${OS_VERSION}"
fi

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
        local check_api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/${BUILD_PATH}/${dir_name}/${version}?ref=${REPO_BRANCH}"
        
        if curl --silent --fail "${check_api_url}" > /dev/null 2>&1; then
            found_codename="$dir_name"
            log "Found matching codename: ${dir_name}" >&2
            break
        fi
    done <<< "$KMOD_DIRS"
    
    # If not found via GitHub, try hardcoded fallback
    if [ -z "$found_codename" ]; then
        log "Could not find codename via GitHub, trying fallback mapping..." >&2
        local version_series=$(echo "$version" | cut -d'.' -f1,2)
        
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

# Find the codename for our version
TRUENAS_NAME=$(find_codename_for_version "${TRUENAS_VERSION}")

if [ -z "${TRUENAS_NAME}" ]; then
    echo "Failed to determine TrueNAS codename for version ${TRUENAS_VERSION}."
    echo "Please build the kernel module manually."
    exit 1
fi

# Construct the module URL
MODULE_URL="${REPO_URL}/${TRUENAS_NAME}/${TRUENAS_VERSION}/led-ugreen.ko"

# ============================================================================
# Version Tracking and Smart Download Logic
# ============================================================================

check_version_and_download() {
    local version_file="${PERSIST_DIR}/.version"
    local stored_version=""
    local need_download=false

    if [ -f "${version_file}" ]; then
        stored_version=$(cat "${version_file}" 2>/dev/null || echo "")
        log "Stored TrueNAS version: ${stored_version:-<none>}"
    else
        log "No version file found, will download kernel module"
        need_download=true
    fi

    if [ "${stored_version}" != "${TRUENAS_VERSION}" ]; then
        log "TrueNAS version changed (${stored_version:-<none>} -> ${TRUENAS_VERSION})"
        need_download=true
    else
        if [ -f "${PERSIST_DIR}/led-ugreen.ko" ]; then
            log "Kernel module already up to date for version ${TRUENAS_VERSION}"
            need_download=false
        else
            log "Kernel module file missing, will download"
            need_download=true
        fi
    fi

    if [ "${need_download}" = "true" ]; then
        log "Verifying kernel module availability..."
        # Use GitHub API to check if the file exists instead of curl --head on raw URLs
        local check_api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/${BUILD_PATH}/${TRUENAS_NAME}/${TRUENAS_VERSION}/led-ugreen.ko?ref=${REPO_BRANCH}"
        if ! curl --silent --fail "${check_api_url}" > /dev/null 2>&1; then
            echo "Kernel module not found for TrueNAS version ${TRUENAS_VERSION}."
            echo "Expected location: ${MODULE_URL}"
            echo "Please build the kernel module manually."
            exit 1
        fi
        return 0  # Need to download
    else
        return 1  # Skip download
    fi
}

if check_version_and_download; then
    NEED_MODULE_DOWNLOAD=true
else
    NEED_MODULE_DOWNLOAD=false
fi

# ============================================================================
# Read-Only Filesystem Detection
# ============================================================================

check_and_remount_readonly() {
    local mount_point="$1"
    local mount_opts

    mount_opts=$(mount | grep " on ${mount_point} " | awk '{print $6}' | tr -d '()' || echo "")

    if [[ "${mount_opts}" == *"ro"* ]]; then
        log "Detected read-only filesystem at ${mount_point}"
        if mount -o remount,rw "${mount_point}" 2>/dev/null; then
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

# Detect read-only root
if ! check_and_remount_readonly "/usr" 2>/dev/null; then
    READONLY_ROOT=true
    log "Read-only root filesystem detected - using persistent directory for all files"
fi

# Try to remount /etc as writable
BOOT_POOL_PATH="boot-pool/ROOT/${OS_VERSION}"
if [ -d "/${BOOT_POOL_PATH}/etc" ]; then
    check_and_remount_readonly "/${BOOT_POOL_PATH}/etc" 2>/dev/null || true
fi

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

if [ ! -d "${CLONE_DIR}/.git" ]; then
    log "Cloning ugreen_leds_controller repository..."
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would clone repository to ${CLONE_DIR}"
    else
        git clone https://github.com/miskcoo/ugreen_leds_controller.git "${CLONE_DIR}" -q
        log "Repository cloned successfully"
        CLONED_REPO=true
    fi
else
    log "Repository already present in ${CLONE_DIR}"
    if [ "${FORCE}" = "true" ]; then
        log "FORCE: removing and re-cloning repository"
        if [ "${DRY_RUN}" != "true" ]; then
            rm -rf "${CLONE_DIR}"
            git clone https://github.com/miskcoo/ugreen_leds_controller.git "${CLONE_DIR}" -q
            CLONED_REPO=true
        fi
    fi
fi

# ============================================================================
# Kernel Module Installation
# ============================================================================

install_kernel_module() {
    local module_dest="${PERSIST_DIR}/led-ugreen.ko"
    local kernel_ver
    kernel_ver=$(uname -r)

    if [ "${NEED_MODULE_DOWNLOAD}" = "true" ]; then
        log "Downloading kernel module to persistent directory..."
        if [ "${DRY_RUN}" = "true" ]; then
            log "DRY RUN: would download module to ${module_dest}"
        else
            if ! curl -sSL -o "${module_dest}" "${MODULE_URL}"; then
                echo "Kernel module download failed." >&2
                exit 1
            fi
            chmod 644 "${module_dest}"
            log "Kernel module downloaded successfully"

            # Update version file
            echo "${TRUENAS_VERSION}" > "${PERSIST_DIR}/.version"
            log "Updated version tracker to ${TRUENAS_VERSION}"
        fi
    else
        log "Kernel module download skipped (already up to date)"
    fi

    # For writable systems, also copy to standard location
    if [ "${READONLY_ROOT}" = "false" ]; then
        if [ "${DRY_RUN}" = "true" ]; then
            log "DRY RUN: would also copy to /lib/modules/${kernel_ver}/extra/"
        else
            mkdir -p "/lib/modules/${kernel_ver}/extra" 2>/dev/null || true
            cp "${module_dest}" "/lib/modules/${kernel_ver}/extra/led-ugreen.ko" 2>/dev/null || \
                log "Note: could not copy to /lib/modules (read-only filesystem)"
        fi
    fi
}

install_kernel_module

# ============================================================================
# Module Loading Configuration
# ============================================================================

log "Configuring kernel module loading..."
if [ "${DRY_RUN}" = "true" ]; then
    log "DRY RUN: would create /etc/modules-load.d/ugreen-led.conf"
else
    cat <<EOL > /etc/modules-load.d/ugreen-led.conf
i2c-dev
led-ugreen
ledtrig-oneshot
ledtrig-netdev
EOL
    chmod 644 /etc/modules-load.d/ugreen-led.conf
fi

log "Loading kernel modules..."
if [ "${DRY_RUN}" = "true" ]; then
    log "DRY RUN: would load kernel modules"
else
    modprobe -a i2c-dev ledtrig-oneshot ledtrig-netdev || true
    # Load custom module using insmod with absolute path
    if [ -f "${PERSIST_DIR}/led-ugreen.ko" ]; then
        insmod "${PERSIST_DIR}/led-ugreen.ko" || log "Warning: failed to load led-ugreen module"
    elif [ -f "/lib/modules/$(uname -r)/extra/led-ugreen.ko" ]; then
        modprobe led-ugreen || log "Warning: failed to load led-ugreen module"
    else
        log "Warning: led-ugreen.ko not found"
    fi
fi

# ============================================================================
# Configuration File Setup
# ============================================================================

CONFIG_FILE="${PERSIST_DIR}/ugreen-leds.conf"
TEMPLATE_CONFIG="${CLONE_DIR}/scripts/ugreen-leds.conf"

# Priority 1: Use existing config in persistent directory
if [ -f "$CONFIG_FILE" ] && [ "${FORCE}" != "true" ]; then
    log "Using existing configuration file at ${CONFIG_FILE}"
    echo ""
    echo "Note: Review ${TEMPLATE_CONFIG} for new options"
    echo ""

    if [ "${AUTO_YES}" != "true" ]; then
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

    if [ "${AUTO_YES}" != "true" ]; then
        echo ""
        echo "Note: Review ${TEMPLATE_CONFIG} for new options"
        echo ""
        read -r -p "Modify LED configuration now? (y/n): " MODIFY_CONF
        if [[ "$MODIFY_CONF" == "y" ]]; then
            nano "$CONFIG_FILE"
            if [ "${DRY_RUN}" != "true" ]; then
                cp "$CONFIG_FILE" /etc/ugreen-leds.conf
            fi
        fi
    fi
# Priority 3: Use template for new installations
else
    log "No existing configuration found, using template"

    if [ "${AUTO_YES}" != "true" ]; then
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
# Network Interface Detection
# ============================================================================

log "Detecting network interfaces..."
mapfile -t NETWORK_INTERFACES < <(ip -br link show | awk '$1 !~ /^(lo|docker|veth|br|vb)/ && $2 == "UP" {print $1}')

CHOSEN_INTERFACE=""
if [ ${#NETWORK_INTERFACES[@]} -eq 0 ]; then
    log "Warning: No network interfaces detected"
else
    ACTIVE_INTERFACES=()
    for interface in "${NETWORK_INTERFACES[@]}"; do
        if ifconfig "$interface" 2>/dev/null | grep -q "UP"; then
            ACTIVE_INTERFACES+=("$interface")
        fi
    done

    if [ ${#ACTIVE_INTERFACES[@]} -eq 0 ]; then
        log "No active interfaces detected"
    elif [ ${#ACTIVE_INTERFACES[@]} -eq 1 ]; then
        CHOSEN_INTERFACE="${ACTIVE_INTERFACES[0]}"
        log "Detected active interface: ${CHOSEN_INTERFACE}"
    else
        if [ "${AUTO_YES}" = "true" ]; then
            CHOSEN_INTERFACE="${ACTIVE_INTERFACES[0]}"
            log "Selected first active interface: ${CHOSEN_INTERFACE}"
        else
            echo "Multiple active interfaces detected: ${ACTIVE_INTERFACES[*]}"
            echo "Please choose one interface:"
            select CHOSEN_INTERFACE in "${ACTIVE_INTERFACES[@]}"; do
                if [[ -n "$CHOSEN_INTERFACE" ]]; then
                    echo "Selected: ${CHOSEN_INTERFACE}"
                    break
                else
                    echo "Invalid selection. Please try again."
                fi
            done
        fi
    fi
fi

# ============================================================================
# Service Cleanup
# ============================================================================

check_and_remove_existing_services() {
    local service_name="ugreen-netdevmon"
    log "Checking for existing ${service_name} services..."

    for service in /etc/systemd/system/multi-user.target.wants/${service_name}@*.service; do
        if [ -e "$service" ]; then
            local interface
            interface=$(basename "$service" | sed "s/${service_name}@\(.*\)\.service/\1/")
            log "Found existing service for interface ${interface}"

            if [ "${FORCE}" = "true" ] || [ "${AUTO_YES}" = "true" ]; then
                if [ "${DRY_RUN}" != "true" ]; then
                    systemctl stop "${service_name}@${interface}.service" 2>/dev/null || true
                    systemctl disable "${service_name}@${interface}.service" 2>/dev/null || true
                    rm -f "$service" || true
                    log "Removed ${service_name}@${interface}.service"
                fi
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

install_scripts_and_services() {
    if [ ! -d "${CLONE_DIR}" ]; then
        log "Repository directory not found; skipping service setup"
        return 0
    fi

    log "Installing scripts and services..."
    cd "${CLONE_DIR}"

    # Create scripts directory in persistent location
    local scripts_dest="${PERSIST_DIR}/scripts"
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would create ${scripts_dest}"
    else
        mkdir -p "${scripts_dest}"
    fi

    # Copy scripts
    local scripts=("ugreen-diskiomon" "ugreen-netdevmon" "ugreen-probe-leds" "ugreen-power-led")
    for script in "${scripts[@]}"; do
        if [ -f "scripts/${script}" ]; then
            if [ "${DRY_RUN}" = "true" ]; then
                log "DRY RUN: would copy scripts/${script} to ${scripts_dest}/"
            else
                cp "scripts/${script}" "${scripts_dest}/"
                chmod +x "${scripts_dest}/${script}"
            fi
        fi
    done

    # Also copy to /usr/bin if writable (backward compatibility)
    if [ "${READONLY_ROOT}" = "false" ]; then
        for script in "${scripts[@]}"; do
            if [ -f "scripts/${script}" ]; then
                if [ "${DRY_RUN}" != "true" ]; then
                    cp "scripts/${script}" /usr/bin 2>/dev/null || \
                        log "Note: could not copy ${script} to /usr/bin"
                fi
            fi
        done
    fi

    # Update and install service files
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would update and install service files"
    else
        for svc in scripts/systemd/*.service; do
            [ -e "${svc}" ] || continue
            local svc_name
            svc_name=$(basename "${svc}")

            # Update paths in service file
            sed "s|/usr/bin/ugreen-|${scripts_dest}/ugreen-|g" "${svc}" > "/etc/systemd/system/${svc_name}"
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

log "Enabling and starting services..."

if [ "${DRY_RUN}" = "true" ]; then
    log "DRY RUN: would enable/start ugreen-diskiomon.service"
else
    systemctl enable ugreen-diskiomon.service || true
    systemctl start ugreen-diskiomon.service || true
fi

if [ -n "${CHOSEN_INTERFACE}" ]; then
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: would enable/start ugreen-netdevmon@${CHOSEN_INTERFACE}"
    else
        systemctl enable "ugreen-netdevmon@${CHOSEN_INTERFACE}" || true
        systemctl restart "ugreen-netdevmon@${CHOSEN_INTERFACE}" || true
    fi
fi

# Check for power LED configuration
if [ -f "$CONFIG_FILE" ] && grep -qP '^BLINK_TYPE_POWER=(?!none$).+' "$CONFIG_FILE" 2>/dev/null; then
    log "Enabling ugreen-power-led.service"
    if [ "${DRY_RUN}" != "true" ]; then
        systemctl enable ugreen-power-led.service || true
        systemctl start ugreen-power-led.service || true
    fi
fi

# ============================================================================
# Completion
# ============================================================================

cleanup

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Persistent directory: ${PERSIST_DIR}"
echo "Configuration: /etc/ugreen-leds.conf"
echo ""
echo "For TrueNAS Init/Shutdown Scripts, use:"
echo "  ${PERSIST_DIR}/install_ugreen_leds_controller.sh --yes"
echo ""
echo "Reboot recommended to verify all services start correctly."
echo ""
