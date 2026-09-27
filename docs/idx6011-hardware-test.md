# iDX6011: migrate from the old fork and test upstream beta

This procedure is for the reporter whose **exact DMI product is `iDX6011`** and
whose old klein0r-based installation used a disk-script patch and a
`NETDEV_LED_NAMES="network_stat"` override. It tests official upstream
`v0.4-beta`, pinned to `c830a2293cf5c67c58e5a98ca339b089b2b13fc3`.

`iDX6011` and `iDX6011 Pro` are separate cases. Upstream passes
`write_protocol=smbus-block` for both, but passes the `2` network / `6` disk
parameters only for exact `iDX6011 Pro`. On exact `iDX6011`, the parameter files
can report `-1` / `-1` (automatic defaults; currently one network / eight disk
entries). Neither these defaults nor LED names establish the physical layout.
Record what the beta actually exposes and controls. Do not add Pro parameters
or reinterpret `netdev2` as a LAN LED before testing.

The reported physical-bay order is `ata3 ata4 ata5 ata6 ata1 ata2`. This
candidate applies that ATA order only to exact `iDX6011`; HCTL and serial
mapping remain separate. `auto` continues to select beta only for exact
`iDX6011 Pro`, so this test must retain `--controller-source idx6011`, including
after reboot. Internal `iDX6012` handling is unverified and is not a hardware
support claim.

## 1. Establish the test directory and capture the old installation

Schedule a maintenance window. Keep a local console available for reboot and
rollback. Leave storage workloads and network configuration unchanged during
these checks; background activity may make observations inconclusive.
Run the blocks in order in one root Bash session. After any unexpected error,
stop and retain the logs before proceeding or rolling back.

```bash
sudo bash
set -euo pipefail
read -r -p 'Existing absolute persistent directory under /mnt/: ' PERSIST_DIR
PERSIST_DIR=$(realpath -e -- "$PERSIST_DIR")
case "$PERSIST_DIR" in /mnt/*) ;; *) echo 'Not a pool path'; exit 1 ;; esac
test -f "$PERSIST_DIR/led-ugreen.ko"
test -d "$PERSIST_DIR/scripts"
test "$(cat /sys/class/dmi/id/product_name)" = 'iDX6011'
TEST_DIR=$(mktemp -d "$(dirname "$PERSIST_DIR")/idx6011-beta-test.XXXXXX")
chmod 700 "$TEST_DIR"
printf 'PERSIST_DIR=%q\nTEST_DIR=%q\n' "$PERSIST_DIR" "$TEST_DIR" > "$TEST_DIR/session.env"
printf 'Keep this test directory path for recovery: %s\n' "$TEST_DIR"
cp -a -- "$PERSIST_DIR" "$TEST_DIR/persistent-before"
midclt call initshutdownscript.query > "$TEST_DIR/initshutdown-before.json"
systemctl list-units --all --plain --no-legend 'ugreen-*.service' > "$TEST_DIR/units-before.txt"
systemctl list-unit-files 'ugreen-*.service' > "$TEST_DIR/unit-files-before.txt"
systemctl list-units --state=active --plain --no-legend 'ugreen-*.service' \
  | awk '{print $1}' > "$TEST_DIR/active-before.txt"
shopt -s nullglob
saved_paths=(/etc/ugreen-leds.conf /etc/modules-load.d/ugreen-led.conf
  /etc/systemd/system/ugreen-* /usr/bin/ugreen-*
  "/lib/modules/$(uname -r)/extra/led-ugreen.ko")
existing_paths=()
for path in "${saved_paths[@]}"; do
  if test -e "$path" || test -L "$path"; then existing_paths+=("${path#/}"); fi
done
tar -C / -cpf "$TEST_DIR/system-before.tar" -- "${existing_paths[@]}"
tar -tf "$TEST_DIR/system-before.tar" > "$TEST_DIR/system-before-files.txt"
sha256sum "$TEST_DIR/persistent-before/led-ugreen.ko" > "$TEST_DIR/old-module.sha256"
```

In **System Settings → Advanced → Init/Shutdown Scripts**, record the exact old
installer command, enabled state, timeout, and every LED-related `sed`/patch
command. The JSON backup above preserves the entries as an additional record.
**Disable the old installer and old disk/LED-name workaround entries for this
test.** Do not delete them. A post-init patch could otherwise alter the beta
scripts again. Record the commercial model printed on the unit or box, separately
from DMI, in the report.

Create a reusable evidence collector. It records installed-file metadata and
the loaded module separately; `modinfo` on a path does not identify the binary
already resident in the kernel.

```bash
cat > "$TEST_DIR/capture.sh" <<'CAPTURE'
#!/usr/bin/env bash
set -u
source "$(dirname "$(realpath "$0")")/session.env"
date -u
cat /etc/version
uname -r
cat /sys/class/dmi/id/product_name
cat /sys/class/dmi/id/product_version 2>/dev/null || true
cat /sys/class/dmi/id/board_name 2>/dev/null || true
cat "$PERSIST_DIR/.module-source" 2>/dev/null || true
sha256sum "$PERSIST_DIR/led-ugreen.ko" 2>/dev/null || true
modinfo "$PERSIST_DIR/led-ugreen.ko" 2>/dev/null || true
modinfo -n led-ugreen 2>/dev/null || true
for name in version srcversion parameters/write_protocol parameters/num_netdev_leds parameters/num_disk_leds; do
  printf '\nLoaded module %s: ' "$name"
  cat "/sys/module/led_ugreen/$name" 2>/dev/null || true
done
ls -l /sys/class/leds
lsblk -S -o NAME,HCTL,TRAN,MODEL,SERIAL
for device in /sys/block/sd*; do
  test -e "$device" || continue
  printf '%s -> %s\n' "${device##*/}" "$(readlink -f "$device")"
done
ip -br link
ip -br address
systemctl status --no-pager --full 'ugreen-*.service' || true
systemctl cat ugreen-probe-leds.service ugreen-diskiomon.service ugreen-netdevmon-multi.service || true
journalctl -b --no-pager -u 'ugreen-*.service' || true
journalctl -b -k --no-pager || true
CAPTURE
bash "$TEST_DIR/capture.sh" > "$TEST_DIR/before.log" 2>&1
```

## 2. Stage both installers and prepare migration

Download the candidate under a separate filename. The URL below pins installer commit
`07d1844fbdde4d348b2cc9596a812e5bd81b1a3e` from the test branch; record its SHA-256 as well. Download the rollback installer **before** changing the live setup.
The saved old module is the rollback module for this running kernel; do not
combine this test with a TrueNAS update.

```bash
curl --fail --show-error --location \
  https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/07d1844fbdde4d348b2cc9596a812e5bd81b1a3e/install_ugreen_leds_controller.sh \
  -o "$TEST_DIR/install-beta.sh"
curl --fail --show-error --location \
  https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/b3ce00f649c9e370aec7af6ce93a5551a3dfb785/install_ugreen_leds_controller.sh \
  -o "$TEST_DIR/install-rollback.sh"
bash -n "$TEST_DIR/install-beta.sh"
bash -n "$TEST_DIR/install-rollback.sh"
sha256sum "$TEST_DIR"/install-*.sh > "$TEST_DIR/installers.sha256"
modinfo -F vermagic "$TEST_DIR/persistent-before/led-ugreen.ko"
uname -r
bash "$TEST_DIR/install-beta.sh" --controller-source idx6011 \
  --persist-dir "$PERSIST_DIR" --dry-run --yes 2>&1 | tee "$TEST_DIR/dry-run.log"
```

Confirm the saved old module's vermagic starts with the running kernel version.
For the previously checked TrueNAS **25.10.5** artifact this is
`6.12.95-production+truenas`; other versions need their own exact artifact.
The beta installer must report official tagged upstream beta, not klein0r or
stable master. The dry-run command itself makes no installation changes;
the surrounding `tee` writes the requested test log.

Stop every currently running UGREEN monitor and the probe before unloading.
Do not force an unload. If any service refuses to stop or the module remains
loaded, stop here and inspect the journal.

```bash
mapfile -t running_units < <(systemctl list-units --state=active --plain --no-legend \
  'ugreen-*.service' | awk '{print $1}')
for unit in "${running_units[@]}"; do systemctl stop "$unit"; done
if test -d /sys/module/led_ugreen; then modprobe -r led-ugreen; fi
test ! -d /sys/module/led_ugreen
printf 'Old module confirmed unloaded at %s\n' "$(date -u)" | tee "$TEST_DIR/unloaded-before-beta.log"
```

Prepare the backed-up persistent configuration for this test. Remove only
the legacy LED-name assignment and select ATA mapping; preserve other settings.
The installer copies this persistent config to `/etc/ugreen-leds.conf`, replacing
the old active override there as well. If the persistent and `/etc` files had
different custom settings, reconcile those settings from the backup first.

```bash
if test ! -f "$PERSIST_DIR/ugreen-leds.conf"; then
  cp -a /etc/ugreen-leds.conf "$PERSIST_DIR/ugreen-leds.conf"
fi
python3 - "$PERSIST_DIR/ugreen-leds.conf" <<'CONFIG'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
lines = [line for line in lines if not re.match(
    r'^\s*(?:export\s+)?(?:NETDEV_LED_NAMES|MAPPING_METHOD)\s*=', line)]
path.write_text('\n'.join(lines) + '\nNETDEV_LED_NAMES=""\nMAPPING_METHOD=ata\n')
CONFIG
bash "$TEST_DIR/install-beta.sh" --controller-source idx6011 \
  --persist-dir "$PERSIST_DIR" --yes 2>&1 | tee "$TEST_DIR/install-beta.log"
cmp "$PERSIST_DIR/ugreen-leds.conf" /etc/ugreen-leds.conf
grep -nE '^(NETDEV_LED_NAMES|MAPPING_METHOD)=' \
  "$PERSIST_DIR/ugreen-leds.conf" /etc/ugreen-leds.conf
bash "$TEST_DIR/capture.sh" > "$TEST_DIR/after-install.log" 2>&1
```

## 3. Verify the active beta before physical tests

Check `after-install.log` and the install log:

- `.module-source` must identify `idx6011:miskcoo/ugreen_leds_controller@v0.4-beta`,
  commit `c830a2293cf5c67c58e5a98ca339b089b2b13fc3`, and the tagged artifact path.
- The old module was absent before install, the installer downloaded/validated
  the beta module, and the probe loaded it successfully afterward. A cache marker
  alone is **not** proof of the active binary.
- Compare cached module `modinfo` version/vermagic with the running kernel and
  compare `modinfo -F srcversion "$PERSIST_DIR/led-ugreen.ko"` with
  `/sys/module/led_ugreen/srcversion` if both exist. A missing srcversion is not
  an identity check; keep the unload, download, and probe evidence.
- Loaded `write_protocol` must be `smbus-block`. Record both count parameters
  exactly, including `-1`. Do not require Pro's `2` / `6` on this device.
- List every sysfs LED. Record extra or missing entries and whether the boot
  animation stopped; enumeration alone is not acceptance.
- The probe must have succeeded (a completed oneshot may be `active (exited)`),
  with no failed monitor or I²C/status errors. Inspect the disk monitor's actual
  device-to-LED assignments and the NIC assignment messages.

If a module/probe error occurs, skip activity tests and retain the complete logs.

## 4. Identify one physical LED at a time

This test isolates **kernel LED ID → physical LED**. It does not test disk or
network mapping. Run it from the local console with someone watching the front
panel. Select only a controller LED actually listed in `/sys/class/leds`.
The block stops monitors, toggles only that LED for two seconds, restores its
state, and restarts only services that were active. It performs no raw I²C writes.
Repeat manually for each enumerated controller LED, recording the observation.

```bash
(
  set -euo pipefail
  read -r -p 'One enumerated LED name (power, netdev, netdev2, disk1, ...): ' led
  [[ "$led" =~ ^(power|netdev[0-9]*|disk[0-9]+)$ ]]
  led_dir="/sys/class/leds/$led"
  test -d "$led_dir"
  mapfile -t active < <(systemctl list-units --state=active --plain --no-legend \
    'ugreen-*.service' | awk '{print $1}')
  restored_state=false
  restore_led() {
    set +e
    if "$restored_state"; then
      printf '%s\n' "$old_color" > "$led_dir/color"
      printf '%s\n' "$old_brightness" > "$led_dir/brightness"
      printf '%s\n' "$old_blink" > "$led_dir/blink_type"
      printf '%s\n' "$old_trigger" > "$led_dir/trigger"
    fi
    for unit in "${active[@]}"; do systemctl start "$unit"; done
  }
  trap restore_led EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for unit in "${active[@]}"; do systemctl stop "$unit"; done
  old_color=$(cat "$led_dir/color")
  old_brightness=$(cat "$led_dir/brightness")
  old_trigger=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$led_dir/trigger")
  old_blink=$(python3 - "$led_dir/blink_type" <<'BLINK'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
mode = re.search(r'\[([^]]+)\]', text).group(1)
if mode != 'none':
    delays = re.search(r'delay_on: (\d+), delay_off: (\d+)', text)
    mode += ' ' + delays.group(1) + ' ' + delays.group(2)
print(mode)
BLINK
  )
  test -n "$old_trigger"
  restored_state=true
  printf 'none\n' > "$led_dir/trigger"
  printf 'none\n' > "$led_dir/blink_type"
  printf '255 255 255\n' > "$led_dir/color"
  printf '0\n' > "$led_dir/brightness"
  sleep 2
  cat "$led_dir/max_brightness" > "$led_dir/brightness"
  sleep 2
  printf '%s: record which physical indicator changed\n' "$led"
)
```

| Enumerated sysfs LED | Physical LED observed | Off/on worked? | Notes |
| --- | --- | --- | --- |
| `power` (if present) | | | |
| `netdev` (if present) | | | |
| `netdev2` (if present) | | | |
| `disk1` … each enumerated disk LED | | | |

Add a row for every enumerated LED. A nonexistent `netdev2` is an observation,
not a reason to add Pro parameters. If a name controls an unexpected indicator,
report it without applying the old `network_stat2` workaround.

## 5. Verify all six SATA bays independently

Use the recorded serial numbers, TrueNAS disk inventory, and known physical bay
labels to fill this table **before generating activity**. Do not infer physical
bay numbers solely from the candidate's expected mapping. Empty bays remain
untested; never remove a live pool member just to complete this table.

| Physical bay | Reported ATA | Actual device | Serial | Sysfs LED from disk monitor | Physical activity observed |
| --- | --- | --- | --- | --- | --- |
| 1 | ata3 | | | | |
| 2 | ata4 | | | | |
| 3 | ata5 | | | | |
| 4 | ata6 | | | | |
| 5 | ata1 | | | | |
| 6 | ata2 | | | | |

Confirm `MAPPING_METHOD=ata` in both configs and that the disk monitor is running.
Select **one** SATA disk identified by serial and bay. The following command reads
at most 256 MiB directly from that disk and discards the data in `/dev/null`.
It writes no disk data. It can wake a sleeping drive and briefly add read load.
Do not swap `if` and `of`, select a boot/USB/NVMe device, or automate this over
all drives. Observe activity against the independent LED table from step 4.

```bash
(
  set -euo pipefail
  read -r -p 'One verified SATA disk path, such as /dev/sda: ' disk
  [[ "$disk" =~ ^/dev/sd[a-z]+$ ]]
  test -b "$disk"
  lsblk -dn -o NAME,TRAN,MODEL,SERIAL "$disk"
  readlink -f "/sys/block/${disk##*/}"
  read -r -p 'Enter the verified serial for this physical bay: ' serial
  test -n "$serial"
  test "$(lsblk -dn -o SERIAL "$disk" | xargs)" = "$serial"
  test "$(lsblk -dn -o TRAN "$disk" | xargs)" = sata
  dd if="$disk" of=/dev/null bs=1M count=256 iflag=direct status=progress
)
```

If direct reads are unsupported or finish too quickly to observe, record the
test as inconclusive; do not switch to a write test. Repeat deliberately for
each identified populated bay. Record background activity or inverted LED
behavior (`LED_INVERT`) rather than interpreting every blink as a mapping fault.

## 6. Verify NIC → LED mapping separately

Record physical port labels, Linux interface names, MAC addresses, link states,
and the monitor's selected LED for each interface. Check any preserved
`NETDEV_INTERFACE_NAMES` override against that inventory. Do not assume sorted
interface order equals the labels on the enclosure, or that `netdev2` is LAN 2.

Choose a connected physical NIC and a known reachable peer on that NIC's subnet.
This sends at most 20 pings and does not change routes, link state, or addresses.
Use the local console when interpreting results. Do not unplug or disable the
interface carrying the management session.

```bash
(
  set -euo pipefail
  ip -br link
  ip -br address
  read -r -p 'Connected physical interface to test: ' iface
  [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]]
  test -e "/sys/class/net/$iface/device"
  test "$(cat "/sys/class/net/$iface/carrier")" = 1
  read -r -p 'Known reachable peer IPv4 address on that subnet: ' peer
  [[ "$peer" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
  ip route get "$peer" oif "$iface"
  ping -n -I "$iface" -c 20 -i 0.2 -w 10 "$peer"
)
```

Record the actual physical indicator and any cross-talk to disk LEDs. Repeat
for another already connected physical NIC. An unconnected or unroutable port
is untested; do not count it as a pass or as a module failure.

## 7. Reboot and repeat the observations

Capture the complete pre-reboot state:

```bash
bash "$TEST_DIR/capture.sh" > "$TEST_DIR/before-reboot.log" 2>&1
printf '/bin/bash %q --controller-source idx6011 --persist-dir %q --yes\n' \
  "$PERSIST_DIR/install_ugreen_leds_controller.sh" "$PERSIST_DIR"
```

Use the printed command in a **new Post Init** entry. Keep the old installer and
patch entries disabled. Set a timeout sufficient for a download and service
startup, for example 300 seconds. Keep the saved test-directory path available.
Reboot through the TrueNAS UI during the maintenance window.

After reboot, open a root Bash session and enter that saved test-directory path:

```bash
sudo bash
set -euo pipefail
read -r -p 'Saved absolute idx6011-beta-test directory: ' TEST_DIR
test -f "$TEST_DIR/session.env"
source "$TEST_DIR/session.env"
bash "$TEST_DIR/capture.sh" > "$TEST_DIR/after-reboot.log" 2>&1
```

Verify the same beta cache marker, module identity evidence and loaded
parameters, LED list, successful probe/monitors, clean journals, and stopped
boot animation. Repeat the six-bay and connected-NIC activity checks and record
any changed ATA/device assignment. Keep `--controller-source idx6011`; an
`auto` rerun on this DMI would select stable upstream and invalidate the test.

## 8. Roll back to the saved old installation

Disable the beta Post Init entry first. Keep the old entries disabled until
the old module and exact saved scripts/configuration are restored. Use the
same TrueNAS/kernel version as the backup. These commands keep the beta
directory for diagnostics and never use `--force`.

If necessary, open root Bash and load `session.env` as in step 7. Then:

```bash
test -f "$TEST_DIR/install-rollback.sh"
test -f "$TEST_DIR/persistent-before/led-ugreen.ko"
test -f "$TEST_DIR/system-before.tar"
test ! -e "$TEST_DIR/persistent-beta"
mapfile -t running_units < <(systemctl list-units --state=active --plain --no-legend \
  'ugreen-*.service' | awk '{print $1}')
for unit in "${running_units[@]}"; do systemctl stop "$unit"; done
if test -d /sys/module/led_ugreen; then modprobe -r led-ugreen; fi
test ! -d /sys/module/led_ugreen
mv -- "$PERSIST_DIR" "$TEST_DIR/persistent-beta"
cp -a -- "$TEST_DIR/persistent-before" "$PERSIST_DIR"
bash "$TEST_DIR/install-rollback.sh" --controller-source idx6011 \
  --persist-dir "$PERSIST_DIR" --yes 2>&1 | tee "$TEST_DIR/rollback-install.log"
mapfile -t running_units < <(systemctl list-units --state=active --plain --no-legend \
  'ugreen-*.service' | awk '{print $1}')
for unit in "${running_units[@]}"; do systemctl stop "$unit"; done
```

The old installer recopies upstream helper scripts. Restore the saved working
scripts **after it runs**, including the reporter's disk-script patch, along
with the exact saved configs and service files:

```bash
test ! -e "$TEST_DIR/persistent-rollback-generated"
mv -- "$PERSIST_DIR" "$TEST_DIR/persistent-rollback-generated"
cp -a -- "$TEST_DIR/persistent-before" "$PERSIST_DIR"
tar -C / -xpf "$TEST_DIR/system-before.tar"
depmod -a
systemctl daemon-reload
while IFS= read -r unit; do
  test -n "$unit" || continue
  systemctl start "$unit"
done < "$TEST_DIR/active-before.txt"
cmp "$TEST_DIR/persistent-before/led-ugreen.ko" "$PERSIST_DIR/led-ugreen.ko"
diff -qr "$TEST_DIR/persistent-before/scripts" "$PERSIST_DIR/scripts"
bash "$TEST_DIR/capture.sh" > "$TEST_DIR/after-rollback.log" 2>&1
```

Compare service enabled states with `unit-files-before.txt` and restore any
differences in those named UGREEN services. Restore the **exact original Post
Init command and its original enabled state**, plus the old workaround entries,
from `initshutdown-before.json`/your UI record. Leave the beta entry disabled.
Verify the old physical LED behavior and reboot persistence. If restore, module
load, or services fail, stop, retain both directories and logs, and report the
error; do not delete caches or force module removal.

## Report and acceptance

Share the commercial label, DMI/version details, installer SHA-256, complete
before/install/after/reboot logs, LED-identification table, six-bay table, and NIC
table. Review logs for personal network details or serials before posting them
publicly. Keep unredacted evidence privately for comparing the same devices.

| Outcome | What it suggests |
| --- | --- |
| Wrong source selected, old override survives, wrong exact-model script patch, failed migration/reload, or lost Post Init profile | Installer/configuration issue; preserve logs before retrying. |
| Confirmed beta loaded with its supplied parameters, but individual sysfs controls target unexpected physical indicators or emit I²C/status errors | Upstream module/layout issue to investigate; do not hide it with the old fork's LED-name workaround. |
| Individual LED identity is correct, but an independently identified serial/bay uses a different ATA port or diskmonitor LED | SATA-to-bay or monitor mapping issue; report both device path and serial. |
| Individual LED identity is correct but traffic selects another indicator | NIC assignment/configuration issue; compare interface order and overrides first. |
| Correct physical LED controls, all six bays verified, connected physical NICs behave independently as observed, healthy services/journals, and identical behavior after reboot | Hardware acceptance for this exact `iDX6011` test configuration. Pro and other models still need separate evidence. |

Missing disks, untested NICs, contradictory observations, or unresolved extra
LEDs leave acceptance incomplete. Keep the draft PR and temporary fallback build
infrastructure until the relevant hardware and reboot gates pass.

**Validation limit:** the shell blocks are syntax-checked; hardware, sysfs,
TrueNAS UI, and reboot behavior require execution on the tester's NAS.
