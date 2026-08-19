# Ugreen LED Controller Installer

Small, single-file Bash installer for the [ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) project. It clones, installs the kernel module, copies helper scripts and a systemd unit, and enables the service.

## Quick install

**Always validate what the script does before running**</br>

Run the following command to install:</br>

```bash
curl -sf https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/main/install_ugreen_leds_controller.sh -o install_ugreen_leds_controller.sh ; sudo bash install_ugreen_leds_controller.sh
```

## Compatibility

> [!NOTE]
> This checklist combines the [upstream project's compatibility status](https://github.com/miskcoo/ugreen_leds_controller) with TrueNAS SCALE reports from this installer repository.
>
> - [x] **means upstream lists the model as tested and working.**
> - [ ] **means upstream has not confirmed the model as tested and working. It does not necessarily mean the model is incompatible; installer-only reports are identified explicitly.**
> ---
> - [x] UGREEN DX4600 Pro
> - [ ] UGREEN DX4600+ — Reported working with TrueNAS SCALE 25.04.2.6 in [this repository's #20](https://github.com/0x556c79/install_ugreen_leds_controller/issues/20).
> - [x] UGREEN DX4700+
> - [x] UGREEN DXP2800 ([upstream #19](https://github.com/miskcoo/ugreen_leds_controller/issues/19); [installer PR #12](https://github.com/0x556c79/install_ugreen_leds_controller/pull/12))
> - [ ] UGREEN DXP2800 GT
> - [ ] UGREEN DXP3800 Plus — Reported working with TrueNAS SCALE 25.10.3 in [this repository's #18](https://github.com/0x556c79/install_ugreen_leds_controller/issues/18).
> - [ ] UGREEN DXP4700 — Reported working with TrueNAS SCALE 25.10.4 in [this repository's PR #25](https://github.com/0x556c79/install_ugreen_leds_controller/pull/25).
> - [x] UGREEN DXP4800 ([upstream #41](https://github.com/miskcoo/ugreen_leds_controller/issues/41); [installer report #6](https://github.com/0x556c79/install_ugreen_leds_controller/issues/6))
> - [x] UGREEN DXP4800 Plus ([upstream Gist](https://gist.github.com/Kerryliu/c380bb6b3b69be5671105fc23e19b7e8))
> - [ ] UGREEN DXP4800 Pro — Reported working only in [this repository's #24](https://github.com/0x556c79/install_ugreen_leds_controller/issues/24), but not tested or confirmed upstream; [#27](https://github.com/0x556c79/install_ugreen_leds_controller/issues/27) reports it not working on TrueNAS SCALE 25.10.4.
> - [ ] UGREEN DXP4800 GT (**Experimental upstream only**, available in [v0.4-beta](https://github.com/miskcoo/ugreen_leds_controller/releases/tag/v0.4-beta), [upstream PR #100](https://github.com/miskcoo/ugreen_leds_controller/pull/100)). This installer has no dedicated or automatically selected DXP4800 GT profile yet.
> - [x] UGREEN DXP6800 Pro ([upstream #7](https://github.com/miskcoo/ugreen_leds_controller/issues/7); [installer report #17](https://github.com/0x556c79/install_ugreen_leds_controller/issues/17))
> - [x] UGREEN DXP8800 Plus ([upstream #1](https://github.com/miskcoo/ugreen_leds_controller/issues/1), [supporting repository](https://github.com/meyergru/ugreen_dxp8800_leds_controller)); developed and tested with this installer on this model.
> - [ ] UGREEN DXP480T Plus ([upstream #6 comment](https://github.com/miskcoo/ugreen_leds_controller/issues/6#issuecomment-2156807225))
> - [ ] UGREEN iDX6011 Pro (**Experimental candidate**, automatically selects upstream [v0.4-beta](https://github.com/miskcoo/ugreen_leds_controller/releases/tag/v0.4-beta); hardware validation is still required in [#23](https://github.com/0x556c79/install_ugreen_leds_controller/issues/23)).
> - [ ] UGREEN iDX6011 / iDX6012 (**Manual experimental only** via `--controller-source idx6011`; not automatically selected or confirmed by this installer).

If upstream confirms another model as working and you have tested this installer on it, feel free to open an issue or pull request here!

### iDX6011 Pro upstream beta source

The iDX6011 family uses a different LED protocol from the stable DX/DXP implementation. This candidate replaces the former third-party source with official upstream `v0.4-beta`, pinned to commit `c830a2293cf5c67c58e5a98ca339b089b2b13fc3`.

The default `--controller-source auto` selects this beta only when the exact DMI product name is `iDX6011 Pro`. Every other model remains on stable upstream `master`. The related `iDX6011` and `iDX6012` names are manual experimental overrides until they have separate hardware reports.

```bash
sudo bash install_ugreen_leds_controller.sh --controller-source auto      # exact Pro selects beta
sudo bash install_ugreen_leds_controller.sh --controller-source idx6011   # force upstream v0.4-beta
sudo bash install_ugreen_leds_controller.sh --controller-source upstream  # force stable master
```

The beta module comes from upstream's tagged [`gh-actions` artifact tree](https://github.com/miskcoo/ugreen_leds_controller/tree/gh-actions/build-scripts/truenas/build/tags/v0.4-beta). That tree currently has exact-version artifacts for the 25.04 and 25.10 trains through 25.10.5; it does not contain 24.04 or 24.10 artifacts. The installer requires an exact `/etc/version` match for this profile and never falls back to an older beta module or to the former third-party branch.

For the exact Pro layout, the expected sysfs LEDs are `power`, `netdev`, `netdev2`, and `disk1` through `disk6`. The monitor assigns detected physical NICs to `netdev` and `netdev2` in sorted order. Optional overrides can be set in `/etc/ugreen-leds.conf`:

```bash
NETDEV_LED_NAMES="netdev netdev2"
NETDEV_INTERFACE_NAMES="enp1s0 enp2s0"
```

An existing exact override of `network_stat network_stat2` is translated at runtime when the new `netdev` paths exist. Other custom LED-name configurations are left unchanged.

For a manual `iDX6011` or `iDX6012` test, keep `--controller-source idx6011` in the TrueNAS Init Script command on every boot. Exact `iDX6011 Pro` systems can use the default `auto` selection.

> [!WARNING]
> Upstream PR #104 was not tested on iDX6011 Pro hardware and its initialization differs from the previously working fork. Keep the fallback available and do not merge this candidate until the probe, both LAN LEDs, all six disk LEDs, and reboot persistence pass on real hardware. The pre-migration installer at commit `b3ce00f` remains the rollback path.

#### iDX6011 Pro hardware test gate

Before installing, record the exact host and bus information and confirm that both the tagged beta artifact and rollback artifact are available:

```bash
cat /etc/version
uname -r
cat /sys/class/dmi/id/product_name
i2cdetect -l
```

Test the candidate first with the explicit beta profile:

```bash
curl -sf https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/migrate-idx6011-upstream-beta/install_ugreen_leds_controller.sh -o install_ugreen_leds_controller.sh
sudo bash install_ugreen_leds_controller.sh --controller-source idx6011
```

Acceptance requires module parameters `smbus-block`, `2`, and `6`; LEDs `power`, `netdev`, `netdev2`, and `disk1`–`disk6`; a stopped rolling boot animation; independent activity on both LAN LEDs; no disk7/disk8, I²C, or status errors; healthy probe/disk/network services; and a successful reboot using the same cached tagged module. After the explicit-profile run passes, rerun with `--controller-source auto` and confirm the same source marker is reused without downloading again.

If any check fails, reinstall the known-working third-party profile with the pre-migration installer and report the captured service/kernel evidence upstream:

```bash
curl -sf https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/b3ce00f/install_ugreen_leds_controller.sh -o install_ugreen_leds_controller.sh
sudo bash install_ugreen_leds_controller.sh --controller-source idx6011
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
├── .installer-source                           # Tagged helper-script source marker
├── .module-source                              # Kernel-module source marker
├── .version                                    # TrueNAS version tracker
├── led-ugreen.ko                               # Kernel module
├── install_ugreen_leds_controller.sh          # Installer copy for reuse
├── ugreen-leds.conf                            # Persistent configuration
└── scripts/                                    # Installed scripts
    ├── ugreen-diskiomon
    ├── ugreen-netdevmon
    ├── ugreen-netdevmon-multi
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
  --controller-source <auto|upstream|idx6011>
                        Select controller source profile (default: auto)
                        auto: beta only for exact iDX6011 Pro DMI
                        upstream: force stable upstream master
                        idx6011: force experimental upstream v0.4-beta

  --uninstall           Fully uninstall: stop services, unload modules, remove files
  --dry-run             Show actions without making changes
  --yes                 Non-interactive mode (assume yes to all prompts)
  --force               Allow destructive actions
```

### Uninstalling

To preview the uninstall (no changes made):

```bash
sudo bash install_ugreen_leds_controller.sh --uninstall --dry-run
```

To fully uninstall:

```bash
sudo bash install_ugreen_leds_controller.sh --uninstall
```

For non-interactive uninstall (skips confirmation prompts):

```bash
sudo bash install_ugreen_leds_controller.sh --uninstall --yes
```

The uninstaller reverses all installation steps: stops services, removes service files, unloads kernel modules, removes configs, scripts, and optionally deletes the persistent directory. No internet access is required.

### How It Works

1. **First Run**: Downloads kernel module, installs scripts, copies installer
2. **Subsequent Runs**: Checks version tracker, reuses existing files if version matches
3. **Version Change**: Automatically downloads new kernel module when TrueNAS updates
4. **Read-Only Detection**: Automatically adapts to read-only `/usr` filesystem

### Troubleshooting

**Check service status:**

```bash
systemctl status ugreen-diskiomon.service
systemctl status ugreen-probe-leds.service
systemctl status ugreen-netdevmon-multi.service
```

**View installer logs:**

```bash
ls -lh /mnt/<POOL>/<PATH>/leds_controller/
cat /mnt/<POOL>/<PATH>/leds_controller/.version
cat /mnt/<POOL>/<PATH>/leds_controller/.module-source
cat /mnt/<POOL>/<PATH>/leds_controller/.installer-source
```

**Force module re-download:**

```bash
rm /mnt/<POOL>/<PATH>/leds_controller/.module-source
/mnt/<POOL>/<PATH>/leds_controller/install_ugreen_leds_controller.sh --yes
```

**Verify module is loaded:**

```bash
lsmod | grep led_ugreen
cat /sys/module/led_ugreen/parameters/write_protocol
cat /sys/module/led_ugreen/parameters/num_netdev_leds
cat /sys/module/led_ugreen/parameters/num_disk_leds
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

Use at your own risk. The author is not responsible for any damage caused by running this script.
