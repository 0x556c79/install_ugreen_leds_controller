# Changelog

All notable changes to this project will be documented in this file.

## [3.0.0] - 2026-11-25

### Behavior changes

Check these before upgrading; details are under Fixed and Removed.

- Installs now refuse a storage folder outside `/mnt/`, including with `--yes`,
  which used to install off-pool. The script itself may run from anywhere.
- `--uninstall` keeps foreign files: anything the installer did not create stays
  in the persistent directory, and the folder goes only if nothing else is in it.
  A folder with no install marker (`.installer-source`, `.module-source`, or the
  `.version` and `led-ugreen.ko` pair v2.0.x left) and no installed service
  pointing at it is not touched at all.
- `--uninstall` refuses a folder with no installation while the installed
  service points at another one, before it removes anything.
- An install refuses to replace an `ugreen_leds_controller` folder in a storage
  folder with no install marker and no installed service pointing at it, unless
  `--force` is given.
- `ugreen-power-led.service` is always enabled and restarted, whatever
  `BLINK_TYPE_POWER` says: it also applies color and brightness, and the old
  check never matched upstream's `"none"`.
- Upstream helper scripts no longer refresh at every boot, only when the module
  is re-downloaded, or on a source change, `--force` or a missing clone.
- A driver that fails to load now exits non-zero instead of printing
  `Installation Complete!`.
- The `/usr/bin` helper copies are gone; services run the persistent copies.
- The legacy `install_ugreen_leds_controller_v1.0.sh` script is removed.
- A newer TrueNAS on the iDX beta profile stops until `IDX_ARTIFACT_COMMIT` is
  bumped to an artifact tree that has its exact version.
- The recommended Post Init timeout is now 60 seconds: the first boot after a
  TrueNAS update downloads a driver and refreshes the upstream scripts.

### Added

- Two-stage `--idx-test collect|install` workflow: automatic hardware report,
  mandatory configuration/file backup before changes, fresh beta installation,
  explicit cached-module loading, service checks and a shareable `feedback.md`.
- `feedback.md` is safe to post: it leaves out journal hostnames, the disk
  serials the monitor logs under `MAPPING_METHOD=serial`, and every `/mnt/` path,
  which shows as `<storage>`.
- A per-test recovery script restores the previous installer-owned files,
  clone, module parameters and service states; early failures also produce a
  report. A new `--idx-test install` beside the same storage folder is refused
  until the last test is rolled back or its folder deleted, so its backup does
  not capture a failed test.
- Reduced the tester guide to collection, installation and visual feedback.

### Changed

#### Hardware-gated upstream iDX6011 Pro beta migration ([#23](https://github.com/0x556c79/install_ugreen_leds_controller/issues/23))

- Repointed the `idx6011` controller profile from the temporary third-party
  implementation to official upstream `v0.4-beta`, pinned to commit
  `c830a2293cf5c67c58e5a98ca339b089b2b13fc3` and to `gh-actions` commit
  `f7f3766146637858e557b1c5c8dbd1e6e0f7d9b7` for its tagged artifact tree.
- Preserved `--controller-source <auto|upstream|idx6011>` while narrowing
  automatic beta selection to the exact `iDX6011 Pro` DMI product name.
  Exact `iDX6011` remains a manual beta test; internal upstream `iDX6012`
  detection is unverified, not a hardware-support claim. An `iDX6011` or
  `iDX6012` install already on `idx6011`, the old fork included, stays on that
  profile and moves to the beta, because stable cannot drive it. All other models
  keep stable upstream `master` behavior.
- The beta profile now requires an exact TrueNAS-version artifact. Its tagged
  tree covers 25.04.0-25.04.2.6 except 25.04.2.2, and 25.10.0-25.10.8, but not
  24.04 or 24.10; it never uses stable, older-version, or third-party fallbacks.
- Source markers now record the upstream tag, commit, and artifact path so an
  existing third-party cache refreshes once and subsequent boots can reuse the
  verified beta artifact.
- Beta downloads are staged in a temporary file, checked with `modinfo` for
  kernel compatibility and required parameters, then atomically installed.
- The upstream probe now owns beta module loading with its generated
  `write_protocol`, network-LED, and disk-LED arguments. The TrueNAS `insmod`
  fallback preserves those arguments and reads DMI from sysfs before using
  `dmidecode`.
- The probe service must complete successfully before disk and network
  monitors start. Source migrations stop dependent services and unload the
  previous module before applying the new profile.
- Updated the dual-network monitor for upstream `netdev`/`netdev2` names,
  deterministic NIC ordering, and removal of the unsupported `invert` write.
  The exact legacy override `network_stat network_stat2` is translated without
  rewriting unrelated custom configuration.
- Removed the fork-specific six-disk script rewrite. The beta module exposes
  `disk1` through `disk6`, and upstream's monitor ignores absent LEDs.

### Fixed

- A normal boot makes no network calls: the clone stays in the persistent folder
  and is refreshed only when the module is re-downloaded, or on a source change,
  `--force`, a missing clone or a changed marker. A failed refresh keeps the
  working clone, and only warns when no module re-download or `--force` needs
  it and the helper scripts and the `ugreen-diskiomon` unit are installed. The
  beta test saves the old clone before it writes the recovery script, so
  recovery always puts it back.
- Module downloads work again on a real host: `modinfo` rejects a temp file whose
  name does not end in `.ko`, so every download failed validation. Partial
  downloads from a killed run are removed by the next download.
- A failed `insmod` or beta probe now fails the run instead of printing
  `Installation Complete!`.
  The next run downloads a new module that failed this way again; a cached module
  stays trusted, so one failed load does not stop the next offline boot.
- Replacing a loaded stable driver now stops the LED services first and fails
  with the services restored if `rmmod` fails. Monitors are always restarted so
  they bind to the new driver, even when a later step of the run fails.
- A failed module swap puts the previous module back with its old arguments and
  restarts the services, also when the beta only reloaded the cached module to
  fix its parameters. Version markers move only once the new module runs, so
  a failed swap never reports "up to date" with the old driver in memory. A beta
  module that was not loaded before the run stays unloaded instead of loading
  without its model parameters.
- A run killed during a module swap is undone by the next run, which puts the
  old module back before it reads the markers. The old module was overwritten
  by the next download before.
- A network error while probing modules now stops the run. Only a real 404
  selects an older module.
- `--uninstall` remounts `/usr` and `/etc` first, finishes the remaining
  cleanup when a removal fails, and reports what was left, including a driver
  that stays loaded, instead of claiming success. The exit code stays 0. On
  closed stdin its confirmation counts as a no. A failed `daemon-reload` only
  warns. A file it could not remove from storage is yours to delete: the install
  markers may be gone by then, so a rerun can leave that folder alone.
- A signal while the run restarts the monitors or cleans up no longer leaves
  `/usr` writable or the monitors stopped.
- `--uninstall` finds the storage folder from the installed service, never
  creates a folder and never asks where to store files.
- The `/mnt/` rule now applies to the storage folder, not the script location:
  `--persist-dir` and `--pool-path` work from any directory, and `--yes` can no
  longer install off-pool. Installs also refuse storage paths with characters
  that break the generated files; spaces stay supported through quoted
  `ExecStart` paths and a quoted Init command. `--idx-test install` refuses such
  paths before it touches the driver.
- The printed Init command now names `/bin/bash`, so it does not depend on the
  execute bit, `--persist-dir` for a folder not named `leds_controller`, so the
  next boot finds the same install, and any `-v` pin, with a reminder to remove
  it after a TrueNAS update. An existing Post Init entry for such a folder needs
  the new command.
- `-v`, `--persist-dir`, `--pool-path` and `--controller-source` fail clearly
  when their value is missing or starts with a dash.
- `--help` and the README now say what `--force` does: it also replaces the LED
  configuration with the template. The README no longer claims edits to
  `/etc/ugreen-leds.conf` persist; each run copies the persistent file over it.
- Prevent filesystem remounts, configuration editor invocation and cleanup
  deletion during `--dry-run`; regression checks cover full install and
  uninstall previews with existing and new configuration.
- Apply the reported `ata3 ata4 ata5 ata6 ata1 ata2` bay order only to exact
  `iDX6011` with the beta profile. Preserve upstream LED names, HCTL/serial
  mappings and all other model mappings, including `iDX6011 Pro`.
- Replace the Pro-only acceptance instructions with a model-specific
  procedure that records physical LED mapping and includes backup and rollback.
- `ugreen-netdevmon-multi` no longer hides failures behind `exit 0`, so
  `Restart=on-failure` works, and it drops its lock file: systemd keeps one copy.
  Any failed LED write at startup now fails the service, not only the last one.
- A `/usr` or `/etc` mount the installer or the beta recovery script made
  writable is put back read-only on exit; a failed restore only warns. The
  installer opens them only after its network steps, so a killed download
  cannot leave them writable. A stacked mount is judged by its top layer.
- The beta recovery script also restores `ugreen-netdevmon@.service` and legacy
  `ugreen-netdevmon@<nic>` instances.
- A beta recovery that cannot unload a busy driver restarts the monitors, says
  so and restores nothing, so it can simply be rerun.
- `--idx-test collect` no longer stops on an off-pool module beside the script
  or in the current folder; it collects in `/tmp` like a machine with no install.
- The beta test prints the recovery command right after the backup, so a dropped
  SSH session does not lose it.
- A first install killed right after the clone is moved into place is no longer
  refused by the next run.
- An uninstall killed part way can be rerun: the files that prove the folder is
  an install are removed last, and the clone is renamed away before it is removed.
  A v2.0.x folder killed just before its `.version` is removed keeps that file
  for you to delete.
- The feedback report also hides the folder of an install outside `/mnt`.

### Removed

- The iDX6011 TrueNAS module build workflow and `build-scripts/truenas/`, kept
  only as a rollback until iDX6011 Pro hardware and reboot acceptance passed on
  TrueNAS SCALE 25.10.8 ([#23](https://github.com/0x556c79/install_ugreen_leds_controller/issues/23)).
- Copies of the helper scripts in `/usr/bin`: units use the persistent copies.
  Uninstall and the beta backup still handle copies from older installs.
- The informational network interface scan, so `ip` is no longer required.
- The LED-name patch of `ugreen-netdevmon`: the installer never starts that
  monitor and removes its `@` instances at boot. Started by hand, it uses
  upstream's `netdev` LED and ignores `NETDEV_LED_NAMES`.

---

## [2.0.9] - 2026-04-18

### Added

#### Kernel Module Version Fallback ([#15](https://github.com/0x556c79/install_ugreen_leds_controller/pull/15))

- When the pre-built `led-ugreen.ko` for the running TrueNAS SCALE version is
  not available on GitHub, the installer now automatically tries earlier patch
  versions within the same `YY.MM` release train (e.g. `25.04.1` → `25.04.0`)
  before failing.
- A clear warning block is logged when a fallback version is used, showing both
  the requested version and the version actually downloaded.
- The `.version` file continues to store the **running** TrueNAS version (not
  the fallback), so skip-download logic on the next boot remains correct.

### Fixed

#### Octal Arithmetic in Patch Version Calculation ([#16](https://github.com/0x556c79/install_ugreen_leds_controller/pull/16))

- Patch version strings like `08` or `09` were treated as invalid octal by
  bash arithmetic expansion, causing the fallback loop to error. Fixed by using
  `$(( 10#$patch ))` to force decimal base.

---

## [2.0.8] - 2026-04-01

### Fixed

#### Kernel Module Loaded Detection

- Replaced `lsmod | grep` with `/sys/module/` sysfs directory check for
  detecting whether kernel modules are already loaded. The previous approach
  could silently fail in certain environments, causing `insmod` to error with
  "File exists" on every re-run.

#### Read-Only Filesystem Detection

- Fixed false-positive read-only detection when mount options contained
  substrings like `errors=remount-ro`. Now matches `ro` as a distinct
  comma-separated mount option.

### Improved

#### Smart Module Reload Logic

- Module loading now skips entirely when `led-ugreen` is already loaded and
  no new version was downloaded — eliminating the redundant `insmod` error
  on re-runs.
- When a new module version is downloaded, the old module is automatically
  unloaded (`rmmod`) before loading the new one (hot-swap).

#### Network Resilience

- Added `--connect-timeout 10` and `--max-time 30` to all `curl` commands
  (120s for module download) to prevent indefinite hangs on network issues.

#### Portability

- Replaced all `grep -oP` (PCRE) usage with portable `sed` and standard
  `grep` alternatives for GitHub API JSON parsing, `/etc/version` extraction,
  and power LED configuration checks.

#### Logging

- Added log message when boot pool path is not found, improving
  troubleshooting visibility.

---

## [2.0.7] - 2026-04-01

### Changed

#### README: Compatibility Table & Disclaimer Cleanup

- Added dedicated **Compatibility** section (placed after Quick Install) with a
  table of confirmed working UGREEN NAS models, references to issues/PRs, and a
  link to the upstream project for broader OS compatibility.
- Reduced **Disclaimer** to a single liability note — hardware compatibility info
  moved to the new section.

#### Installer Output Improvements

- Added `log_separator()` helper to visually separate install phases in output
- Added color-coded service status summary at the end of installation
- Fixed double cleanup message caused by redundant explicit `cleanup()` call
  (the `EXIT` trap already handles it)

### Fixed

#### Kernel Module Availability Check

- Replaced GitHub API `contents` endpoint call with a direct HTTP `HEAD` request
  to `MODULE_URL` when checking for kernel module availability. This avoids
  potential GitHub API rate limiting, simplifies the verification logic, and
  adds `-L` to follow URL redirects.
  — by @sh4tteredd in [#12](https://github.com/0x556c79/install_ugreen_leds_controller/pull/12)

#### Shellcheck Warnings

- Declare `version_series` separately to avoid masking return value (SC2155)
- Quote glob expansion in `for` loop to prevent word splitting (SC2231)

---

## [2.0.6] - 2026-02-22

### Changed

#### Switch to `ugreen-netdevmon-multi` for Network Interface Monitoring

- **`ugreen-netdevmon-multi.service` now enabled by default**: The installer now enables and starts `ugreen-netdevmon-multi.service` instead of the templated `ugreen-netdevmon@<interface>.service`. This service auto-detects all physical ethernet interfaces (`eth*`, `enp*`, `eno*`, `enx*`) and monitors the one with the highest active link speed, switching the `netdev` LED accordingly.
- **No interface selection prompt**: The interactive `select` prompt asking the user to choose a network interface has been removed — it is no longer needed.
- **`ugreen-netdevmon-multi` script now installed**: Added to both the persistent `scripts/` directory and `/usr/bin/` (on writable systems).
- **Legacy `ugreen-netdevmon@` instances cleaned up automatically**: The `check_and_remove_existing_services()` function now unconditionally removes any prior `ugreen-netdevmon@<iface>` instances during reinstall (previously only removed under `--force` or `--yes`).
- **Uninstall updated**: `--uninstall` now stops/disables `ugreen-netdevmon-multi.service` and removes `/usr/bin/ugreen-netdevmon-multi`.

#### Background

The upstream project added `ugreen-netdevmon-multi` on 2026-01-19 (commit `1e4b301`). Our script was already installing the `.service` file (via the generic service-file loop), but never enabling it, and was not copying the corresponding `ugreen-netdevmon-multi` script binary. This release picks up the new service as the primary network monitoring method.

### Fixed

- **`ugreen-netdevmon-multi.service` installed but not started**: Service file was copied to `/etc/systemd/system/` but never enabled or started. Now correctly enabled at install time.
- **Suppress false-alarm `insmod` warning when module already loaded**: The installer now checks `lsmod` before attempting `insmod`; if `led-ugreen` is already in the kernel (e.g. `rmmod` failed during uninstall because the module was in use), a clean informational message is logged instead of a spurious warning.

---

## [2.0.5] - 2026-02-22

### Fixed

#### Service Startup Failure on TrueNAS 25.10.x (Goldeye) ([#11](https://github.com/0x556c79/install_ugreen_leds_controller/issues/11))

- **`depmod -a` now called after module install**: After copying `led-ugreen.ko` to `/lib/modules/<kernel>/extra/`, the installer runs `depmod -a` to register the module with the kernel module system. This ensures `modprobe led-ugreen` succeeds on subsequent boots — previously, the module was only reachable via `insmod` with an absolute path, so `modprobe` would fail at service start and fall through to a DKMS fallback.
- **`ugreen-probe-leds` patched at install time**: The upstream script falls back to `dkms` when `modprobe` fails — `dkms` is not available on TrueNAS. The installer now patches the installed copy of `ugreen-probe-leds` (in both `${PERSIST_DIR}/scripts/` and `/usr/bin/`) to use `insmod <persistent-path>/led-ugreen.ko` as the fallback instead. The patch is idempotent: if already applied, it is skipped.
- **Impact**: Without this fix, all `ugreen-*` services failed to start after a reboot with `A dependency job for ugreen-diskiomon.service failed` and `dkms: command not found` in the journal.

---

## [2.0.4] - 2026-02-22

### Added

#### Uninstall Feature ([#10](https://github.com/0x556c79/install_ugreen_leds_controller/issues/10))

- **`--uninstall` flag**: Fully reverses installation in 9 steps:
  1. Stops and disables all `ugreen-*` systemd services
  2. Removes systemd service files from `/etc/systemd/system/`
  3. Reloads systemd daemon
  4. Unloads kernel modules (`led-ugreen`, `ledtrig-netdev`, `ledtrig-oneshot`, `i2c-dev`)
  5. Removes `/etc/modules-load.d/ugreen-led.conf`
  6. Removes kernel module from `/lib/modules/*/extra/`
  7. Removes scripts from `/usr/bin/`
  8. Removes `/etc/ugreen-leds.conf`
  9. Optionally deletes the persistent directory (with confirmation prompt)
- **No internet required**: Uninstall path skips all GitHub API calls
- **Compatible with existing flags**: Works with `--dry-run`, `--yes`, `--persist-dir`

### Changed

#### Script Architecture

- **Deferred GitHub API calls**: Version fetching wrapped in `fetch_truenas_versions()` function, only called during install flow
- **Early exit gate**: `--uninstall` exits before version detection, cloning, or any install steps

---

## [2.0.3] - 2026-01-07

### Added

#### TrueNAS SCALE 25.10 (Goldeye) Support ([#9](https://github.com/0x556c79/install_ugreen_leds_controller/pull/9))

- Added `TrueNAS-SCALE-Goldeye` to the list of supported codenames
- Version series `25.10.x` now correctly mapped to the Goldeye build directory

### Changed

#### Version Detection Refactor

- **Streamlined GitHub discovery**: Replaced dual-check version validation with a single, streamlined GitHub API lookup via `find_codename_for_version()`
- Eliminated redundant network calls and simplified the version → codename mapping code

### Fixed

#### Log Output Handling

- **stderr redirect for log calls inside functions**: Diagnostic `log` messages inside functions used in command substitution (e.g. `find_codename_for_version`) were leaking into captured output, breaking variable assignment. All such calls now redirect to stderr (`log "..." >&2`).

---

## [2.0.2] - 2024-11-08

### Added

#### Dynamic Version Detection

- **GitHub API Integration**: Script now dynamically fetches available TrueNAS versions from GitHub repository
  - Automatically discovers new TrueNAS versions without script updates
  - Uses GitHub API to query available build directories
  - Builds `KMOD_URLS` array dynamically from repository contents
- **Fallback Mechanism**: Falls back to hardcoded version list if GitHub API is unavailable
  - Network issues handled gracefully
  - API rate limits don't break installation
  - Maintains compatibility if GitHub API changes

### Changed

#### Version Management

- **Future-Proof Design**: New TrueNAS releases automatically supported when added to upstream repository
  - No manual script updates required for new versions
  - Eliminates maintenance burden for version updates
  - User feedback when using dynamic vs fallback mode

### Fixed

#### Code Quality

- **ShellCheck Compliance**: Removed unused `script_parent` variable (lines 167-168)
  - Cleaned up dead code from earlier development
  - Improved script maintainability

### Technical Details

#### API Integration

```bash
# Dynamic fetching
API_URL="https://api.github.com/repos/miskcoo/ugreen_leds_controller/contents/build-scripts/truenas/build?ref=gh-actions"
KMOD_DIRS=$(curl -s "${API_URL}" | grep -oP '"name":\s*"\K(TrueNAS-SCALE-[^"]+)')

# Fallback on failure
if [ ${#KMOD_URLS[@]} -eq 0 ]; then
    # Use hardcoded list
fi
```

#### Benefits

- Automatic support for future TrueNAS versions (Honeybadger, etc.)
- Reduced maintenance overhead
- Better error handling and user feedback
- Maintains backward compatibility

---

## [2.0.1] - 2024-11-08

### Fixed

#### TrueNAS Init Script Execution

- **Script Location Awareness**: Fixed persistent directory detection when script is executed from TrueNAS Init Script
  - Script now correctly detects if it's running from inside a `leds_controller` directory and uses that location
  - Checks for existing `leds_controller` directory at same level as script before creating new one
  - In non-interactive mode (`--yes`), uses script parent directory intelligently
  - Added validation to ensure script runs under `/mnt/` (TrueNAS requirement)
- **Improved Auto-Detection Logic**: Enhanced `determine_persistent_directory()` function with proper priority:
  1. Explicit `--persist-dir` flag (highest priority)
  2. `--pool-path` flag
  3. Script already in `leds_controller/` directory (NEW)
  4. Existing `leds_controller/` at same level as script (NEW)
  5. `--use-current-dir` flag
  6. Interactive selection or script parent in non-interactive mode

#### Documentation

- **README.md**: Added "Script Location Requirements" section explaining automatic detection behavior
- **README.md**: Enhanced "TrueNAS UI Integration" section with better Init Script setup instructions
- **README.md**: Added examples showing how script detects and reuses existing `leds_controller` directory

### Technical Details

- Prevents script abortion when run from Init Script by properly detecting execution context
- Ensures persistent directory is correctly identified regardless of current working directory
- Maintains backward compatibility with all existing installation methods

## [2.0.0] - 2024-11-08

### Added - TrueNAS Scale Read-Only Filesystem Support

#### Core Features

- **Persistent Directory Storage**: All files now stored in user-specified location on writable ZFS pool instead of system directories
- **Version Tracking**: `.version` file tracks TrueNAS version to skip unnecessary module downloads
- **Smart Download Logic**: Only downloads kernel module when version changes or file is missing
- **Read-Only Filesystem Detection**: Automatically detects and adapts to read-only `/usr` filesystem
- **Self-Copy Mechanism**: Installer copies itself to persistent directory for reuse by Init Scripts

#### CLI Options

- `--persist-dir <path>` - Specify explicit persistent storage directory
- `--use-current-dir` - Use current working directory as base for leds_controller/ folder
- `--pool-path <path>` - Specify ZFS pool path under /mnt/ for persistent storage
- `--yes` - Non-interactive mode (assume yes to all prompts)
- `--dry-run` - Preview actions without making changes
- `--force` - Allow destructive actions

#### Functions

- `determine_persistent_directory()` - Interactive/automated persistent directory selection
- `check_version_and_download()` - Version tracking and download decision logic
- `check_and_remount_readonly()` - Read-only filesystem detection and remount attempts
- `copy_installer_to_persistent_dir()` - Self-copy mechanism for Init Script reuse
- `install_kernel_module()` - Smart module installation to persistent directory
- `install_scripts_and_services()` - Service setup with dynamic path updates

#### Configuration Management

- **Automatic Configuration Migration**: Detects existing `/etc/ugreen-leds.conf` and migrates to persistent directory
- **Three-Priority System**: 1) Persistent directory config, 2) System config (migrated), 3) Template (new installs)
- **Preserved Settings**: User configurations automatically preserved during migration from standard installation

#### Documentation

- **README.md**: Comprehensive TrueNAS Scale section with installation options and troubleshooting
- **ADAPTATION_GUIDE.md**: Detailed technical documentation of all changes (720 lines)
- **TESTING.md**: Complete testing guide with 17 test scenarios (507 lines)
- **MIGRATION.md**: Step-by-step migration guide from standard installation (498 lines)
- **QUICK_START.md**: Quick reference card for common operations (277 lines)
- **IMPLEMENTATION_SUMMARY.md**: Project overview and statistics (433 lines)

### Changed

#### Installation Behavior

- **Module Location**: Now installed to `${PERSIST_DIR}/led-ugreen.ko` instead of `/lib/modules/${KERNEL_VER}/extra/`
- **Scripts Location**: Now installed to `${PERSIST_DIR}/scripts/` instead of `/usr/bin/`
- **Module Loading**: Uses `insmod` with absolute path instead of `modprobe` for persistent directory modules
- **Service Files**: Systemd services dynamically updated to reference persistent directory paths
- **Repository Clone**: Now cloned to `${PERSIST_DIR}/ugreen_leds_controller/` instead of current directory

#### Error Handling

- Graceful handling of read-only filesystem errors
- Better network failure detection and reporting
- Directory permission validation before installation
- Service installation verification with fallbacks

#### Logging

- Replaced simple `echo` with timestamped `log()` function
- Added structured logging throughout installation process
- Clear status messages for version tracking decisions

### Improved

#### Backward Compatibility

- On writable systems, files installed to BOTH persistent directory and system directories
- Existing installations continue to work without modification
- Migration path provided for upgrading standard installations

#### User Experience

- Interactive directory selection with clear prompts
- Multiple installation methods for different use cases
- Progress indicators and status messages throughout installation
- Comprehensive help text with examples

#### Reliability

- No longer breaks on TrueNAS updates (when used with Init Scripts)
- Automatic recovery after version changes
- Faster subsequent runs (no re-download when version matches)
- Persistent configuration across reboots and updates
- Automatic configuration migration preserves user settings during upgrades

### Fixed

- Installation failure on systems with read-only `/usr` filesystem
- Unnecessary module re-downloads on every boot
- Service failures after TrueNAS system updates
- Missing error handling for network failures
- Inadequate validation of installation directories

### Technical Details

#### Statistics

- **Lines of Code**: 266 → 741 (+178%)
- **Functions**: 2 → 8 (+300%)
- **CLI Options**: 2 → 9 (+350%)
- **Documentation**: ~200 lines → 2,500+ lines (1,150% increase)

#### Persistent Directory Structure

```
${PERSIST_DIR}/
├── .version                                    # TrueNAS version tracker
├── led-ugreen.ko                               # Kernel module
├── install_ugreen_leds_controller.sh          # Installer copy
├── ugreen_leds_controller/                    # Cloned repository
│   └── scripts/
│       ├── ugreen-leds.conf                   # Template config
│       └── systemd/*.service                  # Service templates
└── scripts/                                    # Installed scripts
    ├── ugreen-diskiomon
    ├── ugreen-netdevmon
    ├── ugreen-probe-leds
    └── ugreen-power-led
```

#### Service Path Updates

Services now reference persistent directory:

```
Before: ExecStart=/usr/bin/ugreen-diskiomon
After:  ExecStart=/mnt/tank/apps/leds_controller/scripts/ugreen-diskiomon
```

#### Module Loading

```bash
# Before
modprobe led-ugreen

# After (read-only systems)
insmod ${PERSIST_DIR}/led-ugreen.ko

# After (writable systems) - fallback chain
insmod ${PERSIST_DIR}/led-ugreen.ko || modprobe led-ugreen
```

### Security

- No changes to security model
- Configuration still stored in `/etc/ugreen-leds.conf` (system-managed permissions)
- Scripts and modules stored with appropriate permissions (644 for modules, 755 for scripts)
- No new privileged operations introduced

### Performance

- **First Run**: ~15-30 seconds (includes download)
- **Subsequent Runs**: ~3-5 seconds (reuses existing files)
- **Init Script Execution**: ~5-8 seconds (non-interactive mode)
- **Network Usage**: ~500KB-1MB initial download only

### Known Limitations

- Single persistent directory per installation (no multi-location support)
- Manual configuration required for multiple network interfaces beyond first
- Dependent on persistent pool being mounted at boot
- Requires TrueNAS Init Scripts feature for automatic startup

### Upgrade Notes

- Existing standard installations continue to work unchanged
- Migration to persistent directory is optional but recommended
- **Configuration Automatically Migrated**: Existing `/etc/ugreen-leds.conf` is detected and copied to persistent directory
- See MIGRATION.md for detailed upgrade procedures
- Old files in `/usr/bin` and `/lib/modules` remain but become unused after migration
- User settings are preserved during migration process

---

## [1.0.0] - 2024-XX-XX (Prior to Adaptation)

### Initial Release

- Basic installation script for UGREEN LED controller
- Installation to standard system directories (`/usr/bin`, `/lib/modules`)
- Manual repository cloning and script copying
- Basic service setup and enablement
- Simple CLI with `-h` and `-v` options
- Requires writable `/usr` filesystem
- No version tracking or persistence mechanism

---

## Compatibility

### Supported TrueNAS Versions

- TrueNAS Scale 24.04.x (Dragonfish)
- TrueNAS Scale 24.10.x (ElectricEel)
- TrueNAS Scale 25.04.x (Fangtooth)
- TrueNAS Scale 25.10.x (Goldeye)

### Filesystem Compatibility

- ✅ Read-only root filesystem (with Nvidia drivers)
- ✅ Writable root filesystem (traditional)
- ✅ Mixed (read-only `/usr`, writable `/etc`)

### Installation Methods

- ✅ Interactive installation with directory selection
- ✅ Non-interactive with `--yes` flag
- ✅ Automated via TrueNAS Init Scripts
- ✅ Multiple CLI options for directory specification

---

## Migration Path

### From v1.0.0 to v2.0.0

1. Stop existing services
2. Download new installer
3. Run with persistent directory option
4. Verify services updated
5. Optionally remove old files
6. Configure TrueNAS Init Script

See [MIGRATION.md](MIGRATION.md) for detailed instructions.

---

## Links

- **Repository**: <https://github.com/0x556c79/install_ugreen_leds_controller>
- **Original Project**: <https://github.com/miskcoo/ugreen_leds_controller>
- **Issues**: <https://github.com/0x556c79/install_ugreen_leds_controller/issues>
- **Wiki**: <https://github.com/0x556c79/install_ugreen_leds_controller/wiki>

---

## Credits

- UGREEN LED controller by miskcoo

---

**Note**: This changelog documents changes from the perspective of the install_ugreen_leds_controller wrapper script. For changes to the underlying ugreen_leds_controller project, see its repository.
