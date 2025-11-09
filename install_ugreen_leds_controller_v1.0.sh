#!/usr/bin/env bash
set -e

# Cleanup function to remove the ugreen_leds_controller folder
cleanup() {
    echo "Cleaning up..."
    rm -rf "$CLONE_DIR"
    echo "Cleanup completed."
}

help() {
    echo "Installation helper for ugreen_leds_controller. Needs to be run as root"
    echo
    echo "Syntax: install_ugreen_leds_controller.sh [-h] [-v <version>]"
    echo "options:"
    echo "-h      Print this help."
    echo "-v      Use predefined TrueNAS version. If not specified it will be extracted from the OS," 
    echo "        but pre-built binaries might not exist. Use format X.Y.Z (X.Y.Z.W applicable as well)."
    echo
}

# Variables
REPO_URL="https://raw.githubusercontent.com/miskcoo/ugreen_leds_controller/refs/heads/gh-actions/build-scripts/truenas/build"
KMOD_URLS=(
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-ElectricEel"
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Dragonfish"
    "https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Fangtooth"
)
TRUENAS_VERSION=""

# Handle arguments first
while getopts ":hv:" option; do
    case "$option" in
        h)
            help
            exit;;
        v)
            TRUENAS_VERSION=${OPTARG};;
        \?)
            echo "Invalid command line option -${OPTARG}. Use -h for help."
            exit 1
    esac
done

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

# Use current working directory as installation and working directory
INSTALL_DIR="$(pwd)"

# Enforce working directory must be under /mnt/<POOL_NAME>/
if [[ "$INSTALL_DIR" != /mnt/* ]]; then
    echo "ERROR: The script must be run from a directory under /mnt/<POOL_NAME>/."
    echo "Current directory: $INSTALL_DIR"
    exit 1
fi

# Prevent running directly from /home (just in case)
if [[ "$INSTALL_DIR" == /home/* ]]; then
    echo "ERROR: Do not run or install from /home. Use a directory under /mnt/<POOL_NAME>/"
    exit 1
fi

# Set the clone directory
CLONE_DIR="$INSTALL_DIR/ugreen_leds_controller"

# Initialize an empty array for supported versions
SUPPORTED_VERSIONS=()
for URL in "${KMOD_URLS[@]}"; do
    HTML_CONTENT=$(curl -s "$URL")
    VERSIONS=$(echo "$HTML_CONTENT" | grep -oE 'TrueNAS-SCALE-[^/]*/[0-9]+(\.[0-9]+)*' | grep -oE '[0-9]+(\.[0-9]+)*')
    while IFS= read -r VERSION; do
        SUPPORTED_VERSIONS+=("$VERSION")
    done <<< "$VERSIONS"
done

SUPPORTED_VERSIONS=($(echo "${SUPPORTED_VERSIONS[@]}" | tr ' ' '\n' | sort -u))
OS_VERSION=$(cat /etc/version | grep -oP '^[0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?')
if [ -z "${TRUENAS_VERSION}" ]; then
    TRUENAS_VERSION=${OS_VERSION}
fi

TRUENAS_SERIES=$(echo "$TRUENAS_VERSION" | cut -d'.' -f1,2)

if [[ "$TRUENAS_SERIES" == "24.10" ]]; then
    TRUENAS_NAME="TrueNAS-SCALE-ElectricEel"
elif [[ "$TRUENAS_SERIES" == "24.04" ]]; then
    TRUENAS_NAME="TrueNAS-SCALE-Dragonfish"
elif [[ "$TRUENAS_SERIES" == "25.04" ]]; then
    TRUENAS_NAME="TrueNAS-SCALE-Fangtooth"
else
    echo "Unsupported TrueNAS SCALE version series: ${TRUENAS_SERIES}."
    echo "Please build the kernel module manually."
    exit 1
fi

if [[ ! " ${SUPPORTED_VERSIONS[@]} " =~ " ${TRUENAS_VERSION} " ]]; then
    echo "Unsupported TrueNAS SCALE version: ${TRUENAS_VERSION}."
    echo "Please build the kernel module manually."
    exit 1
fi

MODULE_URL="${REPO_URL}/${TRUENAS_NAME}/${TRUENAS_VERSION}/led-ugreen.ko"

echo "Checking if kernel module exists for TrueNAS version ${TRUENAS_VERSION}..."
if ! curl --head --silent --fail "${MODULE_URL}" > /dev/null; then
    echo "Kernel module not found for TrueNAS version ${TRUENAS_VERSION}."
    echo "Please build the kernel module manually."
    exit 1
fi

BOOT_POOL_PATH="boot-pool/ROOT/${OS_VERSION}"

echo "Remounting boot-pool datasets with write access..."
mount -o remount,rw "${BOOT_POOL_PATH}/usr" || exit 1
mount -o remount,rw "${BOOT_POOL_PATH}/etc" || exit 1

# Clone the Ugreen LEDs Controller repository into subdirectory if not already present
if [ ! -d "$CLONE_DIR/.git" ]; then
    echo "Cloning Ugreen LEDs Controller repository into $CLONE_DIR..."
    git clone https://github.com/miskcoo/ugreen_leds_controller.git "$CLONE_DIR" -q
    echo "Repository successfully cloned into $CLONE_DIR"
else
    echo "Repository already present in $CLONE_DIR"
fi

# Install the kernel module
echo "Installing the kernel module..."
mkdir -p "/lib/modules/$(uname -r)/extra"
curl -so "/lib/modules/$(uname -r)/extra/led-ugreen.ko" "${MODULE_URL}" || { echo "Kernel module download failed. Exiting"; exit 1; }
chmod 644 "/lib/modules/$(uname -r)/extra/led-ugreen.ko"

# Create kernel module load configuration
echo "Creating kernel module load configuration..."
cat <<EOL > /etc/modules-load.d/ugreen-led.conf
i2c-dev
led-ugreen
ledtrig-oneshot
ledtrig-netdev
EOL
chmod 644 /etc/modules-load.d/ugreen-led.conf

echo "Loading kernel modules..."
depmod
modprobe -a i2c-dev led-ugreen ledtrig-oneshot ledtrig-netdev

CONFIG_FILE="$INSTALL_DIR/ugreen-leds.conf"
TEMPLATE_CONFIG="$CLONE_DIR/scripts/ugreen-leds.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Using existing configuration file at $CONFIG_FILE"
    echo ""
    echo "################################################################################################################################################"
    echo "Note: The configuration file from the repository may have new options. Please review $TEMPLATE_CONFIG and update your $CONFIG_FILE if necessary."
    echo "################################################################################################################################################"
    echo ""
    echo "Do you want to modify the LED configuration file now? (y/n)"
    read -r MODIFY_CONF
    if [[ "$MODIFY_CONF" == "y" ]]; then
        nano "$CONFIG_FILE"
    fi
    cp "$CONFIG_FILE" /etc/ugreen-leds.conf
    echo "Configuration file "$CONFIG_FILE" for ugreen-leds copied to /etc/ugreen-leds.conf."
else
    echo "Do you want to modify the LED configuration file now? (y/n)"
    read -r MODIFY_CONF
    if [[ "$MODIFY_CONF" == "y" ]]; then
        nano "$TEMPLATE_CONFIG"
    fi
    cp "$TEMPLATE_CONFIG" /etc/ugreen-leds.conf
    cp "$TEMPLATE_CONFIG" "$CONFIG_FILE"
    chmod 644 /etc/ugreen-leds.conf
    echo "Configuration file for ugreen-leds saved as /etc/ugreen-leds.conf."
fi

echo "Detecting network interfaces..."
NETWORK_INTERFACES=($(ip -br link show | awk '$1 !~ /^(lo|docker|veth|br|vb)/ && $2 == "UP" {print $1}'))

if [ ${#NETWORK_INTERFACES[@]} -eq 0 ]; then
    echo "Warning: No network interfaces detected. Skipping ugreen-netdevmon service setup."
else
    ACTIVE_INTERFACES=()
    for interface in "${NETWORK_INTERFACES[@]}"; do
        if ifconfig "$interface" | grep -q "UP"; then
            ACTIVE_INTERFACES+=("$interface")
        fi
    done

    if [ ${#ACTIVE_INTERFACES[@]} -eq 0 ]; then
        echo "No active interfaces detected. Skipping ugreen-netdevmon service setup."
        exit 0
    elif [ ${#ACTIVE_INTERFACES[@]} -eq 1 ]; then
        CHOSEN_INTERFACE="${ACTIVE_INTERFACES[0]}"
        echo "Detected one active interface: ${CHOSEN_INTERFACE}."
    else
        echo "Multiple active interfaces detected: ${ACTIVE_INTERFACES[*]}"
        echo "Please choose one interface to use:"
        select CHOSEN_INTERFACE in "${ACTIVE_INTERFACES[@]}"; do
            if [[ -n "$CHOSEN_INTERFACE" ]]; then
                echo "You selected: ${CHOSEN_INTERFACE}"
                break
            else
                echo "Invalid selection. Please try again."
            fi
        done
    fi
fi

check_and_remove_existing_services() {
    local service_name="ugreen-netdevmon"
    echo "Checking for existing services matching: ${service_name}@*.service"
    for service in /etc/systemd/system/multi-user.target.wants/${service_name}@*.service; do
        if [ -e "$service" ]; then
            local interface=$(basename "$service" | sed "s/${service_name}@\(.*\)\.service/\1/")
            echo "Found existing service for interface ${interface}. Removing..."
            systemctl stop "${service_name}@${interface}.service" || echo "Warning: Failed to stop ${service_name}@${interface}.service"
            systemctl disable "${service_name}@${interface}.service" || echo "Warning: Failed to disable ${service_name}@${interface}.service"
            rm -f "$service" || echo "Warning: Failed to remove service file"
            echo "Successfully removed ${service_name}@${interface}.service"
        fi
    done
    systemctl daemon-reload
}

check_and_remove_existing_services

# Copy scripts and configure services
echo "Setting up systemd services..."
cd "$CLONE_DIR"

scripts=("ugreen-diskiomon" "ugreen-netdevmon" "ugreen-probe-leds" "ugreen-power-led")
for script in "${scripts[@]}"; do
    chmod +x "scripts/$script"
    cp "scripts/$script" /usr/bin
done

cp scripts/systemd/*.service /etc/systemd/system/
systemctl daemon-reload

echo "Enabling and starting ugreen-diskiomon service..."
systemctl start ugreen-diskiomon.service
systemctl enable ugreen-diskiomon.service

if [ ${#NETWORK_INTERFACES[@]} -eq 0 ]; then
    echo "Warning: No network interfaces detected. Skipping ugreen-netdevmon service setup."
else
    echo "Enabling and starting ugreen-netdevmon service for interface: ${CHOSEN_INTERFACE}..."
    systemctl enable "ugreen-netdevmon@${CHOSEN_INTERFACE}"
    systemctl restart "ugreen-netdevmon@${CHOSEN_INTERFACE}"
fi

# Check if BLINK_TYPE_POWER is enabled
if grep -qP '^BLINK_TYPE_POWER=(?!none$).+' "$CONFIG_FILE"; then
    echo "Enabling and starting ugreen-power-led.service because BLINK_TYPE_POWER is set."
    systemctl enable ugreen-power-led.service
    systemctl start ugreen-power-led.service
else
    echo "BLINK_TYPE_POWER is set to 'none', not enabling ugreen-power-led.service."
fi

cleanup

echo "Setup complete. Reboot your system to verify."
