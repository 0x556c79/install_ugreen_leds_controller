# Changelog

All notable changes to this project will be documented in this file.

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
- **Repository**: https://github.com/0x556c79/install_ugreen_leds_controller
- **Original Project**: https://github.com/miskcoo/ugreen_leds_controller
- **Issues**: https://github.com/0x556c79/install_ugreen_leds_controller/issues
- **Wiki**: https://github.com/0x556c79/install_ugreen_leds_controller/wiki

---

## Credits
- UGREEN LED controller by miskcoo

---

**Note**: This changelog documents changes from the perspective of the install_ugreen_leds_controller wrapper script. For changes to the underlying ugreen_leds_controller project, see its repository.
