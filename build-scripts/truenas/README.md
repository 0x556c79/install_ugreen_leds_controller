# iDX6011 TrueNAS Kernel Module Builds

These scripts build interim TrueNAS SCALE `led-ugreen.ko` modules for
iDX6011/iDX6012 support while upstream artifacts are not available.

The build is intentionally pinned to:

```text
https://github.com/klein0r/ugreen_leds_controller
480f114bae69ec2bb7003df5d9c13f788ca6ace6
```

Artifacts are written under `build-scripts/truenas/build/` using the same layout
that the installer downloads:

```text
build-scripts/truenas/build/<TrueNAS-SCALE-Codename>/<version>/led-ugreen.ko
```

Only the supported TrueNAS SCALE trains are built: 24.04, 24.10, 25.04, and
25.10. The GitHub Actions workflow restores existing artifacts from the
`idx6011-kmods` branch first, builds missing module directories only, and then
publishes the merged build tree back to that branch.

Run a targeted local build with Docker:

```bash
bash build-scripts/truenas/build-all.sh TrueNAS-SCALE-Fangtooth/25.04.0
```
