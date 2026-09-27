# iDX beta review — 2026-09-27

## Source decision

Keep `v0.4-beta` pinned to `c830a2293cf5c67c58e5a98ca339b089b2b13fc3`.
The tag and `dev-idx601-series` still identify this commit. No newer release,
tag or iDX branch commit supersedes it. Reviewed `master` is
`992fc6dcb5da4cfc9aa25561eff2f584c06f586d`; it does not contain the beta
protocol/layout implementation. Switching to master would lose that work.

Relevant later work includes NIC-name discovery (#113), utility builds (#114),
per-disk colors (#99, with ordering issue #109), and open work on probing
(#110/#115), hotplug (#116), and standby (#108). None establishes a newer
accepted iDX beta source. [Maintainer guidance in #111](https://github.com/miskcoo/ugreen_leds_controller/issues/111#issuecomment-4999067449)
still points experimental SMBus users at this beta.

## Exact DMI evidence and limits

The [pinned probe](https://github.com/miskcoo/ugreen_leds_controller/blob/c830a2293cf5c67c58e5a98ca339b089b2b13fc3/scripts/ugreen-probe-leds)
recognizes `iDX6011`, `iDX6011 Pro`, and `iDX6012` for `write_protocol=smbus-block`.
Only exact `iDX6011 Pro` also receives `num_netdev_leds=2 num_disk_leds=6`.
[PR #104](https://github.com/miskcoo/ugreen_leds_controller/pull/104) calls these
the Pro layout parameters. Their absence on `iDX6011` establishes current
code behavior, not a confirmed design intention or final physical layout.

[Issue #93](https://github.com/miskcoo/ugreen_leds_controller/issues/93#issuecomment-4777559813)
contains explicitly non-Pro hardware discussion; its [later correction](https://github.com/miskcoo/ugreen_leds_controller/issues/93#issuecomment-4808180263)
reports the MCU on I801. There is no established evidence that exact DMI
`iDX6011` is a normal alias for retail Pro. Keep `auto` limited to exact Pro,
force the beta profile for the non-Pro test, and collect the commercial model
label with DMI. Internal `iDX6012` detection is not evidence of a shipping or
tested model in this project.

## What the new report proves

[Local issue #23's September report](https://github.com/0x556c79/install_ugreen_leds_controller/issues/23#issuecomment-5848438206)
used the old klein0r commit `480f114bae69ec2bb7003df5d9c13f788ca6ace6` on
TrueNAS 25.10.5 / kernel `6.12.95-production+truenas`. It did not test this beta.

The fork hardcodes two network entries before disk entries. Its observed
`network_stat2 → bay 1` therefore does not establish a beta naming bug.
Forcing the beta Pro layout would still put disk1 after two network IDs and
could reproduce that shift. This is an inference to test, not a hardware
result. Leave upstream LED naming and parameters unchanged for the clean test.

The independently measured bay/ATA order is `ata3 ata4 ata5 ata6 ata1 ata2`.
The pinned disk monitor otherwise uses sequential ports for iDX; its rotated
mapping exists only for DXP6800. The installer now adjusts only the ATA table
for exact `iDX6011` on beta. Pro, HCTL, serial and existing DX/DXP mappings
retain their previous behavior.

## TrueNAS artifact evidence

The [exact official 25.10.5 artifact](https://github.com/miskcoo/ugreen_leds_controller/blob/90b6cb8beb59662b6972e04827105977888c1530/build-scripts/truenas/build/tags/v0.4-beta/TrueNAS-SCALE-Goldeye/25.10.5/led-ugreen.ko)
exists. `modinfo` confirms vermagic `6.12.95-production+truenas` and parameters
`write_protocol`, `num_netdev_leds`, and `num_disk_leds`.
The [successful build log](https://github.com/miskcoo/ugreen_leds_controller/actions/runs/30062740394)
shows `checkout v0.4-beta`, HEAD `c830a22`, and the tagged 25.10.5 output path.
The workflow's master SHA is the build infrastructure revision, not the
module source revision; the explicit checkout is the relevant provenance.

## Candidate changes and verification

- Dry-run no longer remounts filesystems, invokes configuration editors, or
  deletes a clone on cleanup. Other writes remain behind dry-run checks.
- Exact-model ATA correction is applied to both installed script copies.
- Old-cache source changes force an exact beta download. The probe fallback
  preserves upstream module arguments. The hardware procedure additionally
  requires a successful unload before migration; a cache marker alone cannot
  identify the loaded binary.
- README and the [hardware procedure](idx6011-hardware-test.md) separate
  module identity, parameters, physical LED IDs, SATA bays, NIC assignment,
  and reboot behavior. The old fork workaround is excluded from the beta test.

Validation: `bash -n`, `shellcheck`, `git diff --check`, and the offline suite
`python3 -m unittest discover -s tests -v`. The suite checks full dry-run
install/uninstall paths for both profiles with existing/missing storage and
config variants, exact model/profile selection, generated probe arguments,
module validation, source migration, and absence of beta version fallback.
The original installer fails the dry-run regression; the corrected one passes.
These checks do not exercise actual kernel loading, I2C hardware or TrueNAS UI.

## Test and merge decision

Ready for the controlled **exact iDX6011** hardware procedure after these
changes are available on the test branch. This is permission to collect the
missing evidence, not a support or release claim. Physical LED layout, all
populated bays, empty-bay behavior, connected NICs and reboot persistence
remain hardware gates. Missing equipment leaves the corresponding gate open.

Keep PR #28 draft. Non-Pro acceptance does not establish Pro acceptance.
Keep the fallback workflow, build scripts and remote `idx6011-kmods` branch
until the relevant model-specific hardware and reboot gates are satisfied.
The procedure's outcome table distinguishes installer, module/layout, SATA,
and NIC configuration failures before deciding where a fix belongs.
