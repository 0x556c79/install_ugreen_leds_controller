#!/usr/bin/env bash
set -e

# Cleanup function to remove the ugreen_leds_controller folder
cleanup() {
    echo "Cleaning up..."
    rm -rf "$INSTALL_DIR"
    echo "Cleanup completed."
}

help() {
    echo "Installation helper for ugreen_leds_controller. Needs to be run as root"
    echo
    echo "Syntax: install_ugreen_leds_controller.sh [-h] [-tv <version>]"
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
)
TRUENAS_VERSION=""

# Handle arguments first
while getopts ":hv:" option; do
    case "$option" in
        h)  # Help
            help
            exit;;
        v) # Specified TrueNAS version
            TRUENAS_VERSION=${OPTARG};;
        \?) # Unknown option
            echo "Invalid command line option -${OPTARG}. Use -h for help."
            exit 1
    esac
done

# Initialize an empty array for supported versions
SUPPORTED_VERSIONS=()
# Loop through each URL
for URL in "${KMOD_URLS[@]}"; do
    # Fetch the HTML content
    HTML_CONTENT=$(curl -s "$URL")

    # Extract version numbers by targeting the directory format
    VERSIONS=$(echo "$HTML_CONTENT" | grep -oE 'TrueNAS-SCALE-[^/]*/[0-9]+(\.[0-9]+)*' | grep -oE '[0-9]+(\.[0-9]+)*')

    # Append the versions to the SUPPORTED_VERSIONS array
    while IFS= read -r VERSION; do
        SUPPORTED_VERSIONS+=("$VERSION")
    done <<< "$VERSIONS"
done


# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

# Remove duplicates and sort versions
SUPPORTED_VERSIONS=($(echo "${SUPPORTED_VERSIONS[@]}" | tr ' ' '\n' | sort -u))
OS_VERSION=$(cat /etc/version | grep -oP '^[0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?')
# If no version was specified as an argument, fall back to /etc/version
if [ -z "${TRUENAS_VERSION}" ]; then
    TRUENAS_VERSION=${OS_VERSION}
fi
TRUENAS_SERIES=$(echo "$TRUENAS_VERSION" | cut -d'.' -f1,2)

# Map version to TrueNAS name
if [[ "$TRUENAS_SERIES" == "24.10" ]]; then
    TRUENAS_NAME="TrueNAS-SCALE-ElectricEel"
elif [[ "$TRUENAS_SERIES" == "24.04" ]]; then
    TRUENAS_NAME="TrueNAS-SCALE-Dragonfish"
else
    echo "Unsupported TrueNAS SCALE version series: ${TRUENAS_SERIES}."
    echo "Please build the kernel module manually."
    exit 1
fi

# Validate full version
if [[ ! " ${SUPPORTED_VERSIONS[@]} " =~ " ${TRUENAS_VERSION} " ]]; then
    echo "Unsupported TrueNAS SCALE version: ${TRUENAS_VERSION}."
    echo "Please build the kernel module manually."
    exit 1
fi

# Construct the kernel module URL
MODULE_URL="${REPO_URL}/${TRUENAS_NAME}/${TRUENAS_VERSION}/led-ugreen.ko"

# Test if the kernel module URL is valid
echo "Checking if kernel module exists for TrueNAS version ${TRUENAS_VERSION}..."
if ! curl --head --silent --fail "${MODULE_URL}" > /dev/null; then
    echo "Kernel module not found for TrueNAS version ${TRUENAS_VERSION}."
    echo "Please build the kernel module manually."
    exit 1
fi

# Variables for remount paths
BOOT_POOL_PATH="boot-pool/ROOT/${OS_VERSION}"

# Until next reboot we need write access
# Remount boot-pool datasets with write access
echo "Remounting boot-pool datasets with write access..."
mount -o remount,rw "${BOOT_POOL_PATH}/usr" || exit 1
mount -o remount,rw "${BOOT_POOL_PATH}/etc" || exit 1

# Get the current non-root user and their home directory
INSTALL_USER=${SUDO_USER:-$USER}
INSTALL_HOME=$(eval echo ~$INSTALL_USER)

# Set the target directory for cloning
INSTALL_DIR=${INSTALL_DIR:-"$INSTALL_HOME/ugreen_leds_controller"}

# Ensure the home directory exists and navigate to it
if [ ! -d "$INSTALL_HOME" ]; then
    echo "Home directory for $INSTALL_USER does not exist. Exiting."
    exit 1
fi

cd "$INSTALL_HOME" || { 
    echo "Failed to change directory to $INSTALL_HOME"; 
    exit 1; 
}

# Clone the Ugreen LEDs Controller repository
echo "Cloning Ugreen LEDs Controller repository..."
if git clone https://github.com/miskcoo/ugreen_leds_controller.git "$INSTALL_DIR" -q; then
    # Change ownership to the original user
    chown -R $INSTALL_USER:$INSTALL_USER "$INSTALL_DIR"
    echo "Repository successfully cloned into $INSTALL_DIR"
else
    echo "Repository cloning failed"
    exit 1
fi

# Install the kernel module
echo "Installing the kernel module..."
mkdir -p "/lib/modules/$(uname -r)/extra"
curl -so "/lib/modules/$(uname -r)/extra/led-ugreen.ko" "${MODULE_URL}" || echo "Kernel module download failed. Exiting" exit 1
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

# Load kernel modules
echo "Loading kernel modules..."
depmod
modprobe -a i2c-dev led-ugreen ledtrig-oneshot ledtrig-netdev

CONFIG_FILE="$INSTALL_HOME/ugreen-leds.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Using existing configuration file at $CONFIG_FILE"
    cp $CONFIG_FILE /etc/ugreen-leds.conf
else
    # Ask user if they want to modify the configuration file
    echo "Do you want to modify the LED configuration file now? (y/n)"
    read -r MODIFY_CONF
    if [[ "$MODIFY_CONF" == "y" ]]; then
        nano "$INSTALL_DIR/scripts/ugreen-leds.conf"
    fi
    # Copy the configuration file
    cp $INSTALL_DIR/scripts/ugreen-leds.conf /etc/ugreen-leds.conf && cp $INSTALL_DIR/scripts/ugreen-leds.conf $CONFIG_FILE
    chmod 644 /etc/ugreen-leds.conf
    echo "Configuration file for ugreen-leds saved /etc/ugreen-leds.conf."
fi

# Detect active network interfaces and configure services
echo "Detecting network interfaces..."
NETWORK_INTERFACES=($(ip -br link show | awk '$1 !~ /^(lo|docker|veth|br|vb)/ && $2 == "UP" {print $1}'))

if [ ${#NETWORK_INTERFACES[@]} -eq 0 ]; then
    echo "Warning: No network interfaces detected. Skipping ugreen-netdevmon service setup."
else
    # Check which interfaces are active
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
    
    # Find all matching services in the specified location
    for service in /etc/systemd/system/multi-user.target.wants/${service_name}@*.service; do
        if [ -e "$service" ]; then
            local interface=$(basename "$service" | sed "s/${service_name}@\(.*\)\.service/\1/")
            echo "Found existing service for interface ${interface}. Removing..."
            
            # Stop the service if running
            systemctl stop "${service_name}@${interface}.service" || echo "Warning: Failed to stop ${service_name}@${interface}.service"
            
            # Disable the service
            systemctl disable "${service_name}@${interface}.service" || echo "Warning: Failed to disable ${service_name}@${interface}.service"
            
            # Remove the service file
            rm -f "$service" || echo "Warning: Failed to remove service file"
            
            echo "Successfully removed ${service_name}@${interface}.service"
        fi
    done
    
    # Reload systemd daemon
    systemctl daemon-reload
}

check_and_remove_existing_services

# Copy scripts and configure services
echo "Setting up systemd services..."
cd $INSTALL_DIR

scripts=("ugreen-diskiomon" "ugreen-netdevmon" "ugreen-probe-leds")
for script in "${scripts[@]}"; do
    chmod +x "scripts/$script"
    cp "scripts/$script" /usr/bin
done

cp scripts/systemd/*.service /etc/systemd/system/
systemctl daemon-reload

# Enable and start diskiomon service
echo "Enabling and starting ugreen-diskiomon service..."
systemctl start ugreen-diskiomon.service
systemctl enable ugreen-diskiomon.service

# Enable and start netdevmon services for all detected interfaces
if [ ${#NETWORK_INTERFACES[@]} -eq 0 ]; then
    echo "Warning: No network interfaces detected. Skipping ugreen-netdevmon service setup."
else
    echo "Enabling and starting ugreen-netdevmon service for interface: ${CHOSEN_INTERFACE}..."
    systemctl enable "ugreen-netdevmon@${CHOSEN_INTERFACE}"
    systemctl restart "ugreen-netdevmon@${CHOSEN_INTERFACE}"
fi

# Call cleanup function
cleanup

echo "Setup complete. Reboot your system to verify."
