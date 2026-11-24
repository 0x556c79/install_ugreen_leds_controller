# AGENTS.md

Guidance for Agents when working in this repository.

## Project Overview

A single Bash installer script that sets up the [ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) on TrueNAS SCALE. It downloads a pre-built kernel module, installs systemd services, handles read-only root filesystems, and persists across system updates via ZFS pool storage.

**Latest released version:** v2.0.9 (2026-04-18); current development remains unreleased
**Main file:** `install_ugreen_leds_controller.sh`

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
25.04 and 25.10 trains (the pinned artifact commit covers 25.04.0-25.04.2.6
except 25.04.2.2, and 25.10.0-25.10.7); it must not fall back to an older module.

## Running the Script

```bash
# Must be run as root
sudo bash install_ugreen_leds_controller.sh               # auto-detect version, interactive
sudo bash install_ugreen_leds_controller.sh -v 25.04.0.1  # pin a specific TrueNAS version
sudo bash install_ugreen_leds_controller.sh --uninstall   # remove services, modules and installer files
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
| `--idx-test <collect\|install>` | Collect hardware feedback or run a backed-up beta installation test |
| `--uninstall` | Full uninstall (services, modules, installer-owned files; other files in storage stay) |
| `--dry-run` | Preview all actions without executing |
| `--yes` | Non-interactive mode (skips all prompts) |
| `--force` | Re-clone the upstream scripts and replace the LED configuration with the template |

## Script Architecture

The script is a single file organized into named functions. The main ones:

| Function | Purpose |
| -------- | ------- |
| `log()` | Timestamped stdout logging (UTC) |
| `log_separator()` | Visual section divider |
| `cleanup()` | EXIT hook that ignores further signals; if a module swap never finished, restores the old module; starts any service the run stopped and did not restart, and those of an install already on this version when its update failed, then remounts `REMOUNTED_RW` read-only newest first, warning on failure. The clone stays for offline boots |
| `help()` | Prints usage |
| `fetch_truenas_versions()` | GitHub API discovery of codename folders; warns when the API returns nothing |
| `find_codename_for_version()` | Maps TrueNAS version → build codename, falling back to a hardcoded table |
| `run_idx_test()` | Runs collection or a backed-up beta test with a feedback report and recovery script; the clone moves into the backup before that script exists, because recovery deletes it; a new test waits until the last one is rolled back |
| `select_controller_profile()` | Selects stable master or the pinned upstream beta from CLI and exact DMI; runs again once the storage folder is known when an `iDX6011`/`iDX6012` install on `auto` is marked `idx6011:`, because stable cannot drive it |
| `probe_candidate_url()` | Probes with one retry; a remaining network error stops the install |
| `resolve_module_url()` | Resolves stable fallbacks or requires an exact tagged beta artifact; only a 404 moves to an older candidate |
| `require_flag_value()` | Rejects a value flag whose value is missing or starts with a dash |
| `find_installed_persist_dir()` | Reads the storage folder back from the installed `ugreen-diskiomon` unit, canonicalised because v2.0.x wrote the path as typed |
| `persist_path_problem()` | Says why an install cannot use a path; shared by the installer and `--idx-test install` |
| `has_install_marker()` | True when the storage folder holds `.installer-source` or `.module-source`, `.version` with `led-ugreen.ko`, or the installed unit points at it (v2.0.x wrote no marker, and a TrueNAS update removes the unit); only then is a clone there the installer's |
| `determine_persistent_directory()` | Selects, canonicalises and validates ZFS storage; uninstall also checks the installed unit and never creates it |
| `check_and_remount_readonly()` | Detects and remounts read-only boot-pool datasets; records each success in `REMOUNTED_RW` |
| `prepare_writable_system()` | Remounts `/usr` and `/etc` for install and uninstall; sets `READONLY_ROOT` |
| `check_version_and_download()` | Smart download — skips if version and source are unchanged and the module is present; before a needed download it queues the monitors of an install already on this version for `cleanup()`, so a failed lookup still brings them up |
| `copy_installer_to_persistent_dir()` | Self-replicates for use as TrueNAS Init Script |
| `clone_is_optional()` | True when no module change or `--force` needs the clone and the scripts and a unit are already installed |
| `abort_clone()` | Removes the `CLONE_NEW` folder; continues when the clone is optional, otherwise stops. The working clone stays |
| `clone_controller_repository()` | Refreshes the clone only on a module change, `--force`, a missing clone or a changed marker; verifies in `CLONE_NEW`, then swaps with two renames through `CLONE_OLD` |
| `install_kernel_module()` | Downloads, validates, atomically caches, and installs the selected `.ko`, keeping the old one as `led-ugreen.ko.previous`, which the next run puts back if this one is killed; makes `/usr` writable only now, after the network steps |
| `unload_led_module()` | Records the module arguments and runs `rmmod`; a failure stops the run and `cleanup()` restarts the services |
| `restore_previous_module()` | Puts `led-ugreen.ko.previous` back, also over an existing `/lib/modules` copy, and, unless it never left memory, reloads the cached module with its old arguments; a beta module that was not loaded before the run stays with the probe |
| `module_load_failed()` | Clears `.version` only for a fresh download with no older module to return to, so the next run downloads again and a cached module keeps booting offline, then exits non-zero |
| `commit_module_markers()` | Writes `.version` and `.module-source`, only once the new module runs |
| `patch_probe_leds_script()` | Preserves upstream module arguments in the TrueNAS `insmod` fallback |
| `patch_diskiomon_script()` | Applies the reported ATA order only to exact non-Pro iDX6011 on beta |
| `patch_netdevmon_multi_script()` | Writes the network monitor, which maps ordered NICs to stable, upstream-beta or old-fork network LED names |
| `check_and_remove_existing_services()` | Removes legacy `ugreen-netdevmon@*` instances |
| `install_scripts_and_services()` | Copies scripts to `$PERSIST_DIR/scripts/`, installs systemd units pointing at them; keeps the installed ones when the clone is missing or its marker differs after a failed optional refresh |
| `print_service_status()` | Color-coded service status summary |
| `uninstall_remove()` | Removes one path, recording a failure instead of stopping the cleanup |
| `uninstall_all()` | 9-step full uninstall; deletes only `PERSIST_FILES`, `HELPER_SCRIPTS`, clones and partial `.led-ugreen.ko.download.*` files from storage, and nothing from a folder without an install marker or matching unit. Refuses a folder with no install while the unit points elsewhere |

## Key Constraints

- Script must be run as **root**.
- Persistent storage must be under `/mnt/<pool>/` — survives TrueNAS updates. Installs refuse any other location and paths with `"`, `'`, `\`, `&`, `|`, `%`, `$`, backtick or control characters; spaces and non-ASCII stay allowed. Uninstall has neither restriction.
- TrueNAS SCALE mounts `/usr` and `/etc` read-only by default; the script detects this, remounts with write access as needed and restores read-only on exit.
- Needs internet access to `raw.githubusercontent.com`, `api.github.com` and `github.com` only for a first install, a TrueNAS update, a source change, `--force` or a missing clone or module. A failed clone only warns when no module re-download or `--force` needs it and the scripts and a unit are installed. A normal boot with a matching module and clone makes no network calls. Codename lookup falls back to a hardcoded table.
- Runtime dependencies: `git`, `curl`, `modinfo`, `modprobe`, `insmod`, `rmmod`, `depmod`, `mount`, `realpath`, `systemctl`; `nano` for the interactive config edit, `dmidecode` when sysfs has no DMI name. `--idx-test` also needs `tar`, `sha256sum`, `journalctl` and `findmnt`.
- `auto` selects upstream `v0.4-beta` only for exact DMI product `iDX6011 Pro`; all other models remain on stable `master`, except iDX6011/iDX6012 installs already on `idx6011`. `idx6011` is the explicit experimental override.
- The beta profile is pinned to tag commit `c830a2293cf5c67c58e5a98ca339b089b2b13fc3` and artifact commit `42b92b609df02504d5175970c3c121d8e40fa3de`. Its probe service must load the module with model-specific parameters before dependent monitors start.
- A newer TrueNAS release needs `IDX_ARTIFACT_COMMIT` bumped: the beta profile only uses exact artifacts from that pinned tree.
- Do not merge the beta candidate or remove `.github/workflows/build-idx6011-truenas-kmods.yml`, `build-scripts/truenas/`, or the remote `idx6011-kmods` rollback branch until real iDX6011 Pro hardware and reboot acceptance pass.

## Validation and temporary fallback tooling

The installer itself has no compilation or package-manager step. Validate it with:

```bash
bash -n install_ugreen_leds_controller.sh
shellcheck install_ugreen_leds_controller.sh
git diff --check
python3 -m unittest discover -s tests -v
```

The repository still contains temporary TrueNAS module build tooling solely for
hardware-test rollback. It is staged for deletion only after upstream beta
hardware acceptance.
