# iDX6011 / iDX6011 Pro: two-stage hardware test

Use this guide on your TrueNAS SCALE NAS to help finish support for your model.
The installer collects the technical details automatically. You only need to
check the physical LEDs and share the report in [issue #23](https://github.com/0x556c79/install_ugreen_leds_controller/issues/23).

## 1. Collect information

Download the installer from the test branch and run its collection mode:

```bash
curl -fL https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/migrate-idx6011-upstream-beta/install_ugreen_leds_controller.sh -o /tmp/install_ugreen_leds_controller.sh
sudo bash /tmp/install_ugreen_leds_controller.sh --idx-test collect
```

This creates a report without changing your LED installation. The console
prints the full path to `feedback.md` and how to display it. Paste its contents
into the issue and add the model name printed on your NAS or packaging.

Collection also works without an existing installation. For the installation
stage, the script detects the existing LED directory or asks you to add
`--persist-dir /mnt/YOUR_POOL/leds_controller` with your actual pool path.

## 2. Install the test version and check the LEDs

Allow a short maintenance window: LED monitoring stops while the installer
replaces the driver and scripts. Run:

```bash
sudo bash /tmp/install_ugreen_leds_controller.sh --idx-test install
```

The installer automatically:

- Backs up the existing LED configuration and installation before changing them.
- Stops LED services, unloads the old driver, and installs the upstream beta.
- Applies the test configuration for the detected model and checks the services.
- Saves the results in a new `feedback.md` and prints its full path.
- Prints a rollback command for restoring the saved installation if needed.

Read the final console result. **Installation success still needs your visual
LED check.** If installation fails, share the report and use the printed
rollback command if you need to restore the previous installation.

After a successful installation, check the LEDs during normal use:

- Power/status: are the expected LEDs lit, with the expected colors?
- Disk bays: during activity on a known disk, does its own bay LED respond?
  Note any swapped, missing, or unexpected LEDs.
- Network: during traffic on each connected port, does the correct LED respond?

Paste the new `feedback.md` into the same issue and add:

> Model on the NAS/packaging: …
> Overall: works / partly works / does not work
> Power/status LEDs: …
> Disk bay LEDs: …
> Network LEDs: …
> Not tested or unexpected behavior: …

Report only what you observed; mark checks you could not perform as untested.
The script cannot determine physical LED positions or colors automatically.
Results for `iDX6011` and `iDX6011 Pro` are evaluated separately.

Keep the backup until the test is accepted. Share `feedback.md`; the separate
installation log and backup are for troubleshooting and recovery.

This test covers the current boot. It does not change TrueNAS Init/Shutdown
entries or reboot the NAS. Collect your feedback before rebooting: existing
startup entries may reapply an older profile or workaround. Reboot acceptance
remains a separate check before release.
