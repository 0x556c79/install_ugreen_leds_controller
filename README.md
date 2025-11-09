# Ugreen LED Controller Installer

Small, single-file Bash installer for the [ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) project. It clones (unless `--no-clone`), installs the kernel module, copies helper scripts and a systemd unit, and enables the service.

## Quick install

**Always validate what the script does before running**</br>

Run the following command to install:</br>

```bash
curl -sf https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/main/install_ugreen_leds_controller.sh -o install_ugreen_leds_controller.sh ; sudo bash install_ugreen_leds_controller.sh
```

## TrueNAS Scale Read-Only Filesystem Support

**NEW**: The installer now supports TrueNAS Scale systems with read-only root filesystems (common when Nvidia drivers are installed).

### Key Features

- ✅ **Persistent Storage**: Stores kernel module and scripts on a writable ZFS pool location
- ✅ **Version Tracking**: Only downloads kernel modules when TrueNAS version changes
- ✅ **Smart Reuse**: Reuses existing files on subsequent boots (no re-download)
- ✅ **Auto-Recovery**: Survives TrueNAS updates when configured as Init Script
- ✅ **Config Preservation**: Your `/etc/ugreen-leds.conf` settings always persist

### Installation Options

#### Important: Script Location Requirements

⚠️ **The script MUST be run from a location under `/mnt/`** (on a ZFS pool) to ensure persistence across reboots on TrueNAS Scale. The script will abort if run from outside `/mnt/`.

#### Automatic Detection

The script intelligently detects the persistent directory location:

1. **Script in `leds_controller/` directory**: If the script is already located in a folder named `leds_controller`, this folder is used as the persistent directory.

   ```bash
   # Example: Script is at /mnt/tank/apps/leds_controller/install_ugreen_leds_controller.sh
   cd /mnt/tank/apps/leds_controller
   sudo bash install_ugreen_leds_controller.sh --yes
   ```

2. **Existing `leds_controller/` at same level**: If a `leds_controller` directory exists at the same level as the script, it will be reused.

   ```bash
   # Example: Script is at /mnt/tank/apps/install_ugreen_leds_controller.sh
   # and /mnt/tank/apps/leds_controller/ already exists
   cd /mnt/tank/apps
   sudo bash install_ugreen_leds_controller.sh --yes
   ```

3. **New installation**: If neither condition above is met, the script creates a new `leds_controller/` directory.

#### Manual Installation Options

#### Option 1: Interactive (Recommended for first-time setup)

```bash
cd /mnt/<POOL>/<DATASET>/<FOLDER>
sudo bash install_ugreen_leds_controller.sh
```

The installer will prompt you to choose a persistent storage location.

#### Option 2: Use Current Directory

```bash
cd /mnt/<POOL>/<DATASET>/<FOLDER>
sudo bash install_ugreen_leds_controller.sh --use-current-dir
```

Creates `leds_controller/` in your current directory.

#### Option 3: Specify Pool Path

```bash
sudo bash install_ugreen_leds_controller.sh --pool-path <POOL>/<DATASET>/<FOLDER>
```

Example: `--pool-path tank/apps/ugreen`

#### Option 4: Explicit Persistent Directory

```bash
sudo bash install_ugreen_leds_controller.sh --persist-dir /mnt/<POOL>/<PATH>/leds_controller
```

### TrueNAS UI Integration (Automatic Startup)

To ensure LED controller starts after every reboot:

1. **Copy the installer to the persistent directory** (if not already there):

   ```bash
   cp install_ugreen_leds_controller.sh /mnt/<POOL>/<PATH>/leds_controller/
   ```

2. Navigate to **System Settings → Advanced → Init/Shutdown Scripts**
3. Click **Add**
4. Configure:
   - **Description**: `UGREEN LED Controller`
   - **Type**: `Command`
   - **Command**: `/bin/bash /mnt/<POOL>/<PATH>/leds_controller/install_ugreen_leds_controller.sh --yes`
   - **When**: `Post Init`
   - **Enabled**: ✓ (checked)
   - **Timeout**: `10` seconds
5. Click **Save**

**Why this works:**

- The script detects it's running from inside the `leds_controller/` directory
- It uses that directory as the persistent storage location
- The `--yes` flag enables non-interactive mode for automated execution
- Version tracking ensures fast subsequent boots (~3-5 seconds, no re-download)

### Persistent Directory Structure

The installer creates the following structure:

```
/mnt/<POOL>/<PATH>/leds_controller/
├── .version                                    # TrueNAS version tracker
├── led-ugreen.ko                               # Kernel module
├── install_ugreen_leds_controller.sh          # Installer copy for reuse
├── ugreen_leds_controller/                    # Cloned repository
│   └── scripts/
└── scripts/                                    # Installed scripts
    ├── ugreen-diskiomon
    ├── ugreen-netdevmon
    ├── ugreen-probe-leds
    └── ugreen-power-led

/etc/ugreen-leds.conf                          # Your configuration (writable)
```

### Configuration Priority

The installer automatically handles configuration in the following priority order:

1. **Existing persistent config**: Uses `${PERSIST_DIR}/ugreen-leds.conf` if it exists
2. **Existing system config**: Migrates `/etc/ugreen-leds.conf` to persistent directory (preserves your settings)
3. **Template config**: Uses repository template for new installations

**Migration Note**: If you have an existing `/etc/ugreen-leds.conf` from a standard installation, it will be automatically detected and copied to your persistent directory on first run, preserving all your custom settings.

### Command-Line Options

```
Options:
  -h                    Print help message
  -v <version>          Use specific TrueNAS version (e.g., 24.10.0)

  --persist-dir <path>  Specify custom persistent storage directory
  --use-current-dir     Use current working directory for leds_controller/ folder
  --pool-path <path>    Specify ZFS pool path under /mnt/

  --dry-run             Show actions without making changes
  --yes                 Non-interactive mode (assume yes to all prompts)
  --force               Allow destructive actions
```

### How It Works

1. **First Run**: Downloads kernel module, installs scripts, copies installer
2. **Subsequent Runs**: Checks version tracker, reuses existing files if version matches
3. **Version Change**: Automatically downloads new kernel module when TrueNAS updates
4. **Read-Only Detection**: Automatically adapts to read-only `/usr` filesystem

### Troubleshooting

**Check service status:**

```bash
systemctl status ugreen-diskiomon.service
systemctl status ugreen-netdevmon@<interface>.service
```

**View installer logs:**

```bash
ls -lh /mnt/<POOL>/<PATH>/leds_controller/
cat /mnt/<POOL>/<PATH>/leds_controller/.version
```

**Force module re-download:**

```bash
rm /mnt/<POOL>/<PATH>/leds_controller/.version
/mnt/<POOL>/<PATH>/leds_controller/install_ugreen_leds_controller.sh --yes
```

**Verify module is loaded:**

```bash
lsmod | grep led_ugreen
```

**Check persistent directory paths in services:**

```bash
grep ExecStart /etc/systemd/system/ugreen-*.service
```

### Migration from Standard Installation

If you have existing installation in system directories:

1. Run the adapted installer with your preferred persistent directory option
2. The script will automatically migrate your `/etc/ugreen-leds.conf` to the persistent directory
3. Service files are updated to reference the new persistent directory paths
4. Old files in `/usr/bin` remain but are unused
5. Optionally remove old files: `rm -f /usr/bin/ugreen-* /lib/modules/*/extra/led-ugreen.ko`

**Your configuration is preserved**: The installer detects existing `/etc/ugreen-leds.conf` and copies it to the persistent directory automatically.

## Additional Notes

- Full usage, configuration details, and troubleshooting: [project Wiki](https://github.com/0x556c79/install_ugreen_leds_controller/wiki)
- Use `--dry-run` to preview actions without changing the system
- Configuration changes in `/etc/ugreen-leds.conf` persist across reboots

## Disclaimer

Use at your own risk.

Tested and developed on a Ugreen DXP8800 Plus NAS. <br>
Also confirmed working on a UGREEN DXP4800 with TrueNAS SCALE 25.04.2.5 (<https://github.com/0x556c79/install_ugreen_leds_controller/issues/6>) (with Version 1.0 of the script)

The author is not responsible for damage caused by running this script.
