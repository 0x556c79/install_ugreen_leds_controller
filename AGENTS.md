# AGENTS.md

Guidance for Agents when working in this repository.

## Project Overview

A single Bash installer script that sets up the [ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) on TrueNAS SCALE. It downloads a pre-built kernel module, installs systemd services, handles read-only root filesystems, and persists across system updates via ZFS pool storage.

**Latest released version:** v2.0.9 (2026-04-18); current development remains unreleased
**Main file:** `install_ugreen_leds_controller.sh`  
**Legacy file (do not use):** `install_ugreen_leds_controller_v1.0.sh`

See `CHANGELOG.md` for full version history and `README.md` for user-facing documentation.

## Supported TrueNAS SCALE Versions

| Series | Codename |
| ------ | -------- |
| 24.04.x | Dragonfish |
| 24.10.x | ElectricEel |
| 25.04.x | Fangtooth |
| 25.10.x | Goldeye |

Stable upstream artifacts cover the table above. The experimental upstream
`v0.4-beta` profile for iDX6011 Pro has exact-version artifacts only for the
25.04 and 25.10 trains (currently through 25.10.5); it must not fall back to an
older module.

## Running the Script

```bash
# Must be run as root
sudo bash install_ugreen_leds_controller.sh               # auto-detect version, interactive
sudo bash install_ugreen_leds_controller.sh -v 25.04.0.1  # pin a specific TrueNAS version
sudo bash install_ugreen_leds_controller.sh --uninstall   # fully remove everything
sudo bash install_ugreen_leds_controller.sh --dry-run     # preview actions without changes
sudo bash install_ugreen_leds_controller.sh --yes         # non-interactive (Init Scripts)
sudo bash install_ugreen_leds_controller.sh --controller-source idx6011 # force upstream beta
sudo bash install_ugreen_leds_controller.sh -h            # help
```

**All CLI flags:**

| Flag | Purpose |
| ---- | ------- |
| `-h` / `--help` | Show help |
| `-v <version>` | Pin TrueNAS version (e.g. `25.10.0.1`) |
| `--persist-dir <path>` | Explicit persistent storage directory |
| `--use-current-dir` | Use `$CWD/leds_controller/` for storage |
| `--pool-path <path>` | ZFS pool path under `/mnt/` |
| `--controller-source <auto\|upstream\|idx6011>` | Exact Pro auto-selection, stable override, or manual upstream beta |
| `--uninstall` | Full uninstall (services, modules, files) |
| `--dry-run` | Preview all actions without executing |
| `--yes` | Non-interactive mode (skips all prompts) |
| `--force` | Allow destructive actions |

## Script Architecture

The script is a single file (~1,960 lines) organized into named functions:

| Function | Purpose |
| -------- | ------- |
| `log()` | Timestamped stdout logging (UTC) |
| `log_separator()` | Visual section divider |
| `cleanup()` | Removes cloned repo on EXIT (trap) |
| `help()` | Prints usage |
| `fetch_truenas_versions()` | GitHub API discovery of supported versions (with hardcoded fallback) |
| `find_codename_for_version()` | Maps TrueNAS version → build codename |
| `select_controller_profile()` | Selects stable master or the pinned upstream beta from CLI and exact DMI |
| `resolve_module_url()` | Resolves stable fallbacks or requires an exact tagged beta artifact |
| `determine_persistent_directory()` | 6-priority logic for selecting ZFS storage location |
| `check_and_remount_readonly()` | Detects and remounts read-only boot-pool datasets |
| `check_version_and_download()` | Smart download — skips if version unchanged and module present |
| `copy_installer_to_persistent_dir()` | Self-replicates for use as TrueNAS Init Script |
| `install_kernel_module()` | Downloads, validates, atomically caches, and installs the selected `.ko` |
| `patch_probe_leds_script()` | Preserves upstream module arguments in the TrueNAS `insmod` fallback |
| `patch_netdevmon_multi_script()` | Maps ordered NICs to stable or upstream-beta network LED names |
| `check_and_remove_existing_services()` | Removes legacy `ugreen-netdevmon@*` instances |
| `install_scripts_and_services()` | Copies scripts to `/usr/bin/`, installs + enables systemd units |
| `print_service_status()` | Color-coded service status summary |
| `uninstall_all()` | 9-step full uninstall |

## Key Constraints

- Script must be run as **root**.
- Persistent storage defaults to a directory under `/mnt/<pool>/` — survives TrueNAS updates. The old v1.0 approach of using `$CWD` directly is no longer the primary path.
- TrueNAS SCALE mounts `/usr` and `/etc` read-only by default; the script detects this and remounts with write access as needed.
- Requires internet access to `raw.githubusercontent.com` and `api.github.com` (falls back to hardcoded version list if unavailable).
- Runtime dependencies: `git`, `curl`, `ip`, `modinfo`, `modprobe`, `depmod`, `systemctl`.
- `auto` selects upstream `v0.4-beta` only for exact DMI product `iDX6011 Pro`; all other models remain on stable `master`. `idx6011` is the explicit experimental override.
- The beta profile is pinned to tag commit `c830a2293cf5c67c58e5a98ca339b089b2b13fc3`. Its probe service must load the module with model-specific parameters before dependent monitors start.
- Do not merge the beta candidate or remove `.github/workflows/build-idx6011-truenas-kmods.yml`, `build-scripts/truenas/`, or the remote `idx6011-kmods` rollback branch until real iDX6011 Pro hardware and reboot acceptance pass.

## Validation and temporary fallback tooling

The installer itself has no compilation or package-manager step. Validate it with:

```bash
bash -n install_ugreen_leds_controller.sh
shellcheck install_ugreen_leds_controller.sh
git diff --check
```

The repository still contains temporary TrueNAS module build tooling solely for
hardware-test rollback. It is staged for deletion only after upstream beta
hardware acceptance.
