"""Offline tests: python3 -m unittest discover -s tests -v. No host mutations."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install_ugreen_leds_controller.sh").read_text()
FIXTURES = ROOT / "tests/fixtures/v0.4-beta"


def function(name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S)
    assert match, name
    return match.group()


def bash(code, **env):
    return subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", code], text=True,
                          capture_output=True, env=dict(os.environ, **env))


class InstallerTests(unittest.TestCase):
    def test_controller_matrix(self):
        code = "\n".join(function(n) for n in ["is_idx6011_pro_product", "select_controller_profile"])
        for model in ["iDX6011", "iDX6011 Pro", "iDX6012", "DXP4800 GT", "DXP6800 Pro", "unknown", ""]:
            for requested in ["auto", "upstream", "idx6011"]:
                with self.subTest(model=model, requested=requested):
                    result = bash(code + '''
log() { :; }
read_system_product_name() { printf "%s" "$MODEL"; }
IDX_UPSTREAM_TAG=v0.4-beta
IDX_UPSTREAM_COMMIT=c830a2293cf5c67c58e5a98ca339b089b2b13fc3
select_controller_profile
printf "%s" "$CONTROLLER_PROFILE"
''', MODEL=model, CONTROLLER_SOURCE=requested)
                    expected = requested if requested != "auto" else ("idx6011" if model == "iDX6011 Pro" else "upstream")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, expected)

    def test_ata_patch_scope_and_preserved_mappings(self):
        original = (FIXTURES / "ugreen-diskiomon").read_text()
        expected = re.sub(r"^ata_map=\(.*\)$", 'ata_map=("ata3" "ata4" "ata5" "ata6" "ata1" "ata2")', original, flags=re.M)
        for model in ["iDX6011", "iDX6011 Pro", "iDX6012", "DXP6800 Pro", "DXP4800", "DX4600", "unknown"]:
            for profile in ["upstream", "idx6011"]:
                with self.subTest(model=model, profile=profile), tempfile.TemporaryDirectory() as tmp:
                    script = Path(tmp) / "disk"
                    script.write_text(original)
                    result = bash(function("patch_diskiomon_script") + '\nlog() { :; }; patch_diskiomon_script "$TARGET"; patch_diskiomon_script "$TARGET"', TARGET=str(script), SYSTEM_PRODUCT_NAME=model, CONTROLLER_PROFILE=profile, DRY_RUN="false")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    # Whole-file comparison locks LED, HCTL, serial and DX/DXP mappings.
                    self.assertEqual(script.read_text(), expected if model == "iDX6011" and profile == "idx6011" else original)
                    subprocess.run(["bash", "-n", str(script)], check=True)

    def test_probe_preserves_upstream_arguments(self):
        for model in ["iDX6011", "iDX6011 Pro", "iDX6012", "DXP6800 Pro"]:
            for fallback in [False, True]:
                with self.subTest(model=model, fallback=fallback), tempfile.TemporaryDirectory() as tmp:
                    script = Path(tmp) / "probe"
                    shutil.copyfile(FIXTURES / "ugreen-probe-leds", script)
                    module = Path(tmp) / "module.ko"
                    module.touch()
                    patched = bash(function("patch_probe_leds_script") + '\nlog() { :; }; patch_probe_leds_script "$TARGET" "$MODULE"', TARGET=str(script), MODULE=str(module))
                    self.assertEqual(patched.returncode, 0, patched.stderr)
                    subprocess.run(["bash", "-n", str(script)], check=True)
                    code = script.read_text()
                    code = code[:code.index("\ni2c_dev=$(find_i2c_dev")]
                    code = re.sub(r'(?ms)^model=""\n.*?^fi\n', 'model="$MODEL"\n', code, count=1)
                    prefix = '''
modprobe() {
    if [[ "$*" == *led-ugreen* ]]; then
        printf "modprobe:%s\\n" "$*"
        return "${FAIL_MODPROBE}"
    fi
}
insmod() { printf "insmod:%s\\n" "$*"; }
'''
                    result = bash(prefix + code, MODEL=model, FAIL_MODPROBE=str(int(fallback)))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    calls = [line for line in result.stdout.splitlines() if line.startswith(("modprobe:", "insmod:"))]
                    self.assertEqual(len(calls), 2 if fallback else 1)
                    for call in calls:
                        self.assertEqual("write_protocol=smbus-block" in call, model.startswith("iDX"))
                        self.assertEqual("num_netdev_leds=2" in call, model == "iDX6011 Pro")
                        self.assertEqual("num_disk_leds=6" in call, model == "iDX6011 Pro")

    def test_old_cache_forces_exact_beta_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            (p / ".version").write_text("25.10.5\n")
            (p / ".module-source").write_text("idx6011:klein0r/ugreen_leds_controller@480f114bae69ec2bb7003df5d9c13f788ca6ace6\n")
            (p / "led-ugreen.ko").touch()
            result = bash(function("check_version_and_download") + '\nlog() { :; }; resolve_module_url() { printf "%s\\n" "$*"; }; check_version_and_download', PERSIST_DIR=tmp, TRUENAS_VERSION="25.10.5", TRUENAS_NAME="TrueNAS-SCALE-Goldeye", CONTROLLER_PROFILE="idx6011", CONTROLLER_MODULE_SOURCE="idx6011:miskcoo/ugreen_leds_controller@v0.4-beta:c830a2293cf5c67c58e5a98ca339b089b2b13fc3")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "25.10.5 TrueNAS-SCALE-Goldeye")

    def test_missing_beta_has_no_version_fallback(self):
        result = bash(function("resolve_module_url") + '''
log() { :; }
probe_module_url() { echo "$1" >&2; return 1; }
CONTROLLER_PROFILE=idx6011
REPO_URL=https://example.invalid/tags/v0.4-beta
IDX_UPSTREAM_TAG=v0.4-beta
REPO_OWNER=miskcoo REPO_NAME=ugreen_leds_controller REPO_BRANCH=gh-actions BUILD_PATH=tags/v0.4-beta
resolve_module_url 25.10.5 TrueNAS-SCALE-Goldeye
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.count("https://example.invalid/"), 1)
        self.assertIn("/25.10.5/led-ugreen.ko", result.stderr)

    def test_beta_module_validation(self):
        for mode in ["valid", "empty", "invalid", "missing_parameter", "wrong_kernel"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                module = Path(tmp) / "module.ko"
                module.write_bytes(b"" if mode == "empty" else b"fixture")
                result = bash(function("validate_downloaded_module") + r'''
modinfo() {
    if [ "$MODE" = invalid ]; then return 1; fi
    if [ "$1" = -F ]; then
        if [ "$MODE" = wrong_kernel ]; then echo other-kernel; else echo running-kernel; fi
    else
        printf "parm: write_protocol:protocol\nparm: num_netdev_leds:count\n"
        if [ "$MODE" != missing_parameter ]; then echo "parm: num_disk_leds:count"; fi
    fi
}
uname() { echo running-kernel; }
CONTROLLER_PROFILE=idx6011
IDX_UPSTREAM_TAG=v0.4-beta
validate_downloaded_module "$MODULE"
''', MODE=mode, MODULE=str(module))
                self.assertEqual(result.returncode == 0, mode == "valid", result.stderr)

    def test_dry_run_entire_install_and_uninstall(self):
        # Rewrite host paths into fixtures and reject mutating commands.
        # Snapshot also catches direct redirections, including configuration writes.
        for profile in ["upstream", "idx6011"]:
            for existing in [False, True]:
                for uninstall in [False, True]:
                    for config in ["persistent", "system", "new"]:
                        for force in [False, True]:
                            with self.subTest(profile=profile, existing=existing, uninstall=uninstall, config=config, force=force), tempfile.TemporaryDirectory() as tmp:
                                root = Path(tmp)
                                tree = root / "host"
                                persist = tree / "mnt/test/leds_controller"
                                clone = persist / "ugreen_leds_controller"
                                for path in ["etc/modules-load.d", "etc/systemd/system/multi-user.target.wants", "sys/class/dmi/id", "sys/module/led_ugreen", "usr/bin", "lib/modules/test/extra", "boot-pool/ROOT/25.10.5/etc", "var/run"]:
                                    (tree / path).mkdir(parents=True, exist_ok=True)
                                (clone / "scripts/systemd").mkdir(parents=True)
                                (clone / ".git").mkdir()
                                (tree / "etc/version").write_text("25.10.5\n")
                                (tree / "sys/class/dmi/id/product_name").write_text("iDX6011\n")
                                (clone / "scripts/ugreen-leds.conf").write_text("BLINK_TYPE_POWER=none\n")
                                for name in ["ugreen-diskiomon", "ugreen-probe-leds", "ugreen-netdevmon", "ugreen-netdevmon-multi", "ugreen-power-led"]:
                                    (clone / "scripts" / name).write_text("#!/bin/bash\n")
                                    (tree / "usr/bin" / name).write_text("old script\n")
                                for name in ["ugreen-probe-leds", "ugreen-diskiomon", "ugreen-netdevmon-multi", "ugreen-power-led"]:
                                    (tree / "etc/systemd/system" / (name + ".service")).write_text("old unit\n")
                                (tree / "etc/modules-load.d/ugreen-led.conf").write_text("led-ugreen\n")
                                (tree / "lib/modules/test/extra/led-ugreen.ko").write_text("old module\n")
                                (persist / "led-ugreen.ko").write_text("cached fork module\n")
                                (persist / ".version").write_text("25.10.5\n")
                                (persist / ".module-source").write_text("old-fork\n")
                                if config != "new":
                                    (persist if config == "persistent" else tree / "etc").joinpath("ugreen-leds.conf").write_text("NETDEV_LED_NAMES=network_stat\n")
                                binpath = root / "bin"
                                binpath.mkdir()
                                log = root / "mutations"
                                stubs = {cmd: 'printf "%s\\n" "$0 $*" >> "$MUTATIONS"; exit 97' for cmd in ["mkdir", "cp", "mv", "rm", "chmod", "nano", "git", "modprobe", "insmod", "rmmod", "depmod", "touch", "tee"]}
                                stubs.update({
                                    "curl": 'if [[ "$*" == *--head* ]]; then printf 200; else printf \'{"name":"TrueNAS-SCALE-Goldeye"}\\n\'; fi',
                                    "mount": 'if (( $# )); then echo "mount $*" >> "$MUTATIONS"; exit 97; fi; printf "fixture on %s type zfs (ro,relatime)\\n" "$HOST/usr" "$HOST/boot-pool/ROOT/25.10.5/etc"',
                                    "systemctl": 'case "$1" in is-active|is-enabled|show|list-unit-files) exit 0;; *) echo "systemctl $*" >> "$MUTATIONS"; exit 97;; esac',
                                    "lsmod": 'printf "led_ugreen 123 0\\nledtrig_oneshot 1 0\\n"',
                                    "ip": 'printf "enp1s0 UP fixture\\n"',
                                    "uname": 'printf "test\\n"',
                                })
                                for cmd, body in stubs.items():
                                    target = binpath / cmd
                                    target.write_text("#!/bin/bash\n" + body + "\n")
                                    target.chmod(0o755)
                                script = root / "installer.sh"
                                script.write_text(re.sub(r"/(?=(?:etc|sys|usr|lib|var|boot-pool)/)", str(tree) + "/", SOURCE))
                                def snapshot():
                                    return {str(p.relative_to(tree)): (p.stat().st_mode, p.read_bytes() if p.is_file() else None) for p in tree.rglob("*")}
                                if not existing:
                                    shutil.rmtree(persist)
                                before = snapshot()
                                env = dict(os.environ, PATH=str(binpath) + ":" + os.environ["PATH"], MUTATIONS=str(log), HOST=str(tree))
                                args = ["bash", str(script), "--dry-run", "--persist-dir", str(persist), "--controller-source", profile]
                                if uninstall:
                                    args.append("--uninstall")
                                if force:
                                    args.append("--force")
                                result = subprocess.run(args, input="y\ny\ny\n", text=True, capture_output=True, env=env, timeout=10)
                                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                                self.assertFalse(log.exists(), log.read_text() if log.exists() else "")
                                self.assertEqual(before, snapshot())
                                self.assertNotIn("Modify LED configuration", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
