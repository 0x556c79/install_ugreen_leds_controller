"""Offline behavior tests for the two-stage iDX tester workflow."""
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

from test_installer import SOURCE, bash, function


class IdxTestModeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.host = self.root / "host"
        self.persist = self.host / "mnt/pool/leds_controller"
        self.run = self.host / "mnt/pool/report"
        self.persist.mkdir(parents=True)
        self.run.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls"
        for path, value in {
            "etc/version": "25.10.5\n",
            "sys/class/dmi/id/product_name": "iDX6011\n",
            "etc/ugreen-leds.conf": "BLINK_TYPE_POWER=none\n",
        }.items():
            self.write(path, value)
        self.stub("uname", 'printf "test-kernel\n"')
        self.stub("findmnt", 'case "$*" in *OPTIONS*) echo rw;; *) echo /;; esac')
        self.stub("mount", 'echo "unexpected mount $*" >> "$CALLS"; exit 97')
        self.stub("systemctl", 'case "$1" in status|cat|list-unit-files|list-units) exit 0;; is-active) exit 0;; is-enabled) echo disabled;; *) echo "$*" >> "$CALLS"; exit 97;; esac')
        self.stub("journalctl", 'echo "fixture journal"')
        self.stub("i2cdetect", 'echo "fixture i2c adapter"')
        self.stub("lspci", 'echo "fixture PCI controller"')
        self.stub("lsblk", 'echo "sda 0:0:0:0 sata fixture"')
        self.stub("modinfo", 'case "$*" in *vermagic*) echo test-kernel;; *srcversion*) echo fixture;; esac')
        self.env = dict(PATH=str(self.bin) + os.pathsep + os.environ["PATH"], CALLS=str(self.calls),
                        PERSIST_DIR=str(self.persist), IDX_TEST_DIR=str(self.run),
                        IDX_TEST_MODE="install", SYSTEM_PRODUCT_NAME="iDX6011", DRY_RUN="false")

    def write(self, path, value):
        target = self.host / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)
        return target

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def remap(self, code):
        return re.sub(r"/(?=(?:etc|sys|usr|lib|var|boot-pool|mnt)/)", str(self.host) + "/", code)

    def execute(self, names, tail, **env):
        code = "\n".join(function(name) for name in names)
        return bash(self.remap(code) + "\n" + tail, **dict(self.env, **env))

    def cli(self, *args):
        script = self.root / "installer.sh"
        script.write_text(self.remap(SOURCE).replace("${EUID:-0}", "0"))
        return subprocess.run(["bash", str(script), *args], cwd=self.root, text=True,
                              capture_output=True, timeout=15, env=dict(os.environ, **self.env))

    def snapshot(self):
        return {str(p.relative_to(self.host)): (p.stat().st_mode, p.read_bytes() if p.is_file() else None)
                for p in self.host.rglob("*")}

    def test_collect_creates_feedback_without_installing(self):
        before = self.snapshot()
        result = self.cli("--idx-test", "collect", "--persist-dir", str(self.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        reports = list(self.persist.parent.glob("ugreen-idx-test-*/feedback.md"))
        self.assertEqual(len(reports), 1)
        report = reports[0].read_text()
        self.assertIn("INFORMATION COLLECTED; INSTALLATION NOT TESTED", report)
        self.assertIn("DMI product_name: iDX6011", report)
        self.assertIn(str(reports[0]), result.stdout)
        self.assertFalse(self.calls.exists())
        after = self.snapshot()
        for path, contents in before.items():
            self.assertEqual(after[path], contents, path)
        self.assertFalse((reports[0].parent / "backup").exists())
        self.assertEqual(reports[0].stat().st_mode & 0o777, 0o600)

    def test_dry_run_creates_no_report_or_changes(self):
        for mode in ("collect", "install"):
            with self.subTest(mode=mode):
                before = self.snapshot()
                result = self.cli("--idx-test", mode, "--dry-run", "--persist-dir", str(self.persist))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(self.calls.exists())

    def test_conflicting_and_invalid_flags_fail_before_changes(self):
        cases = [("--uninstall",), ("--force",), ("-v", "25.10.5"),
                 ("--controller-source", "upstream"), ("--use-current-dir",),
                 ("--pool-path", "pool"), ("--idx-test", "invalid")]
        for extra in cases:
            with self.subTest(extra=extra):
                before = self.snapshot()
                result = self.cli("--idx-test", "collect", "--persist-dir", str(self.persist), *extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(before, self.snapshot())
                self.assertFalse(self.calls.exists())

    def test_backup_preserves_original_files_and_excludes_unrelated_data(self):
        original = "NETDEV_LED_NAMES=network_stat\nBLINK_TYPE_POWER=none\n"
        (self.persist / "ugreen-leds.conf").write_text(original)
        (self.persist / "private-unrelated.txt").write_text("not installer owned")
        result = self.execute(["idx_test_backup"], "idx_test_backup")
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(self.run / "backup/files.tar") as archive:
            name = str(self.persist / "ugreen-leds.conf").lstrip("/")
            self.assertEqual(archive.extractfile(name).read().decode(), original)
            self.assertFalse(any("private-unrelated" in n for n in archive.getnames()))
        self.assertIn(str(self.persist / "led-ugreen.ko"), (self.run / "backup/absent.txt").read_text())
        self.assertEqual((self.run / "rollback.sh").stat().st_mode & 0o777, 0o700)
        syntax = subprocess.run(["bash", "-n", str(self.run / "rollback.sh")], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        self.assertFalse(self.calls.exists())

    def test_recovery_restores_original_config_and_removes_new_installer_files(self):
        config = self.persist / "ugreen-leds.conf"
        config.write_text("CUSTOM=original\n")
        config.chmod(0o640)
        result = self.execute(["idx_test_backup"], "idx_test_backup")
        self.assertEqual(result.returncode, 0, result.stderr)
        config.write_text("CUSTOM=changed\n")
        new_module = self.persist / "led-ugreen.ko"
        new_module.write_text("new beta")
        unrelated = self.persist / "unrelated.txt"
        unrelated.write_text("leave alone")
        self.stub("depmod", 'echo depmod >> "$CALLS"')
        self.stub("systemctl", 'case "$1" in list-units) exit 0;; *) echo "$*" >> "$CALLS";; esac')
        rollback = self.run / "rollback.sh"
        # Same host-path remapping as other offline tests; bypass only root gate.
        rollback.write_text(rollback.read_text().replace("${EUID}", "0"))
        result = subprocess.run(["bash", str(rollback)], text=True, capture_output=True,
                                timeout=10, env=dict(os.environ, **self.env))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(config.read_text(), "CUSTOM=original\n")
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        self.assertFalse(new_module.exists())
        self.assertEqual(unrelated.read_text(), "leave alone")

    def test_failed_service_enumeration_prevents_prepare_mutations(self):
        self.stub("systemctl", 'case "$1" in list-units) exit 12;; *) echo "$*" >> "$CALLS";; esac')
        before = self.snapshot()
        result = self.execute(["idx_test_prepare_install"], "idx_test_prepare_install")
        self.assertEqual(result.returncode, 12)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.calls.exists())

    def test_recovery_restores_installed_module_when_cache_is_missing(self):
        loaded = self.host / "sys/module/led_ugreen"
        loaded.mkdir(parents=True)
        module = self.write("lib/modules/test-kernel/extra/led-ugreen.ko", "original module")
        self.stub("modinfo", 'case "$*" in *vermagic*) echo test-kernel;; *) printf "%s\\n" "$ORIGINAL_MODULE";; esac')
        result = self.execute(["idx_test_backup"], "idx_test_backup", ORIGINAL_MODULE=str(module))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.run / "backup/module-path").read_text().strip(), str(module))
        module.write_text("new beta")
        loaded.rmdir()  # Model a test that stopped before loading the beta.
        self.stub("depmod", ":")
        self.stub("modprobe", ":")
        self.stub("insmod", 'echo "insmod $*" >> "$CALLS"; test "$(cat "$1")" = "original module"')
        self.stub("systemctl", 'case "$1" in list-units) exit 0;; *) echo "$*" >> "$CALLS";; esac')
        rollback = self.run / "rollback.sh"
        rollback.write_text(rollback.read_text().replace("${EUID}", "0"))
        result = subprocess.run(["bash", str(rollback)], text=True, capture_output=True,
                                timeout=10, env=dict(os.environ, **self.env))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(module.read_text(), "original module")
        self.assertIn("insmod " + str(module), self.calls.read_text())

    def test_recovery_remount_failure_stops_before_files_or_services_change(self):
        result = self.execute(["idx_test_backup"], "idx_test_backup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.stub("findmnt", 'case "$*" in *OPTIONS*) echo ro;; *) echo /fixture;; esac')
        self.stub("mount", "exit 1")
        rollback = self.run / "rollback.sh"
        rollback.write_text(rollback.read_text().replace("${EUID}", "0"))
        before = self.snapshot()
        result = subprocess.run(["bash", str(rollback)], text=True, capture_output=True,
                                timeout=10, env=dict(os.environ, **self.env))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot make", result.stdout)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.calls.exists())

    def test_direct_load_uses_cached_binary_and_model_arguments_in_order(self):
        for model in ("iDX6011", "iDX6011 Pro"):
            with self.subTest(model=model):
                loaded = self.host / "sys/module/led_ugreen"
                loaded.mkdir(parents=True, exist_ok=True)
                (self.persist / "led-ugreen.ko").write_text("beta image")
                self.calls.unlink(missing_ok=True)
                self.stub("systemctl", 'case "$1" in list-units) echo ugreen-diskiomon.service;; *) echo "systemctl $*" >> "$CALLS";; esac')
                self.stub("rmmod", 'echo "rmmod $*" >> "$CALLS"; rmdir "$LOADED"')
                self.stub("modprobe", 'echo "modprobe $*" >> "$CALLS"')
                self.stub("insmod", 'echo "insmod $*" >> "$CALLS"; mkdir "$LOADED"')
                result = self.execute(["idx_test_load_cached_module"],
                                      'idx_test_load_cached_module; test "$IDX_TEST_MODULE_LOADED_FROM_CACHE" = true',
                                      SYSTEM_PRODUCT_NAME=model, LOADED=str(loaded))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = self.calls.read_text().splitlines()
                self.assertEqual(calls[:2], ["systemctl stop ugreen-diskiomon.service", "rmmod led-ugreen"])
                insmod = next(line for line in calls if line.startswith("insmod "))
                self.assertIn(str(self.persist / "led-ugreen.ko") + " write_protocol=smbus-block", insmod)
                self.assertEqual("num_netdev_leds=2 num_disk_leds=6" in insmod, model == "iDX6011 Pro")
                self.assertLess(calls.index(insmod), calls.index("systemctl restart ugreen-probe-leds.service"))

    def test_failed_direct_load_does_not_establish_module_identity(self):
        for failure in ("unload", "insmod"):
            with self.subTest(failure=failure):
                loaded = self.host / "sys/module/led_ugreen"
                loaded.mkdir(parents=True, exist_ok=True)
                (self.persist / "led-ugreen.ko").write_text("beta image")
                self.stub("rmmod", "exit 8" if failure == "unload" else 'rmdir "$LOADED"')
                self.stub("modprobe", ":")
                self.stub("insmod", "exit 9")
                result = self.execute(["idx_test_load_cached_module"],
                                      """trap 'printf "identity=%s\\n" "$IDX_TEST_MODULE_LOADED_FROM_CACHE"' EXIT; idx_test_load_cached_module""",
                                      LOADED=str(loaded), IDX_TEST_MODULE_LOADED_FROM_CACHE="true")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("identity=false", result.stdout)

    def test_prepare_clears_legacy_overrides_preserving_unrelated_configuration(self):
        for model in ("iDX6011", "iDX6011 Pro"):
            with self.subTest(model=model):
                config = self.persist / "ugreen-leds.conf"
                config.write_text('CUSTOM_OPTION="keep me"\nNETDEV_LED_NAMES=network_stat\nexport NETDEV_INTERFACE_NAMES=eth0\nMAPPING_METHOD=scsi\n')
                config.chmod(0o640)
                for marker in (".module-source", ".installer-source"):
                    (self.persist / marker).write_text("old fork")
                result = self.execute(["idx_test_prepare_install"], "idx_test_prepare_install", SYSTEM_PRODUCT_NAME=model)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('CUSTOM_OPTION="keep me"', config.read_text())
                self.assertIn('NETDEV_LED_NAMES=""', config.read_text())
                self.assertIn('NETDEV_INTERFACE_NAMES=""', config.read_text())
                self.assertNotIn("network_stat", config.read_text())
                self.assertIn("MAPPING_METHOD=" + ("ata" if model == "iDX6011" else "scsi"), config.read_text())
                self.assertEqual(config.stat().st_mode & 0o777, 0o640)
                self.assertFalse((self.persist / ".module-source").exists())
                self.assertFalse((self.persist / ".installer-source").exists())

    def test_failed_unload_preserves_config_and_cache(self):
        (self.host / "sys/module/led_ugreen").mkdir(parents=True)
        (self.persist / ".module-source").write_text("old source")
        self.stub("rmmod", "exit 1")
        before = self.snapshot()
        result = self.execute(["idx_test_prepare_install"], "idx_test_prepare_install")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_backup_failure_stops_before_prepare_and_writes_failed_feedback(self):
        result = self.execute(["run_idx_test", "idx_test_finish"], """
idx_test_find_persist_dir() { :; }
read_system_product_name() { echo iDX6011; }
idx_test_capture() { echo fixture; }
idx_test_backup() { echo 'backup failed' >&2; return 9; }
idx_test_prepare_install() { echo prepare >> "$CALLS"; }
run_idx_test
""")
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
        self.assertFalse(self.calls.exists())
        report = next(self.persist.parent.glob("ugreen-idx-test-*/feedback.md"))
        self.assertIn("FAILED", report.read_text())
        self.assertIn("backup failed", report.read_text())
        self.assertIn(str(report), result.stdout)
        self.assertNotIn("SUCCESS:", result.stdout)

    def verification_fixture(self):
        tag, commit = "v0.4-beta", "fixturecommit"
        (self.persist / ".module-source").write_text(f"idx6011:miskcoo/ugreen_leds_controller@{tag}:{commit}:gh-actions:build-scripts/truenas/build/tags/{tag}")
        (self.persist / "led-ugreen.ko").write_text("module")
        for name, value in (("write_protocol", "smbus-block"), ("num_netdev_leds", "2"), ("num_disk_leds", "6")):
            self.write("sys/module/led_ugreen/parameters/" + name, value)
        self.write("sys/module/led_ugreen/srcversion", "fixture")
        for led in ("power", "netdev", "netdev2", "disk1", "disk2", "disk3", "disk4", "disk5", "disk6"):
            (self.host / "sys/class/leds" / led).mkdir(parents=True)
        return dict(IDX_UPSTREAM_TAG=tag, IDX_UPSTREAM_COMMIT=commit, IDX_TEST_MODULE_LOADED_FROM_CACHE="true")

    def test_verification_rejects_inactive_monitor_and_wrong_pro_parameters(self):
        env = self.verification_fixture()
        result = self.execute(["idx_test_verify"], "idx_test_verify", **env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.stub("systemctl", '[[ "$*" != *ugreen-diskiomon* ]]')
        result = self.execute(["idx_test_verify"], "idx_test_verify", **env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Service not active", result.stdout)
        self.stub("systemctl", "exit 0")
        self.write("sys/module/led_ugreen/parameters/num_netdev_leds", "1")
        result = self.execute(["idx_test_verify"], "idx_test_verify", SYSTEM_PRODUCT_NAME="iDX6011 Pro", **env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Pro parameters", result.stdout)

    def test_installer_failure_keeps_backup_and_reports_the_error(self):
        result = self.execute(["run_idx_test", "idx_test_finish"], """
idx_test_find_persist_dir() { :; }
read_system_product_name() { echo iDX6011; }
idx_test_capture() { echo fixture; }
idx_test_backup() { echo backup >> "$CALLS"; touch "$IDX_TEST_DIR/backup-proof"; }
idx_test_prepare_install() { echo prepare >> "$CALLS"; }
bash() { echo install >> "$CALLS"; echo 'module download failed'; return 7; }
idx_test_verify() { echo verify >> "$CALLS"; }
run_idx_test
""")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(), ["backup", "prepare", "install"])
        report = next(self.persist.parent.glob("ugreen-idx-test-*/feedback.md"))
        self.assertTrue((report.parent / "backup-proof").exists())
        self.assertIn("module download failed", report.read_text())
        self.assertIn("FAILED", report.read_text())
        self.assertNotIn("SUCCESS:", result.stdout)

    def test_successful_install_runs_backup_refresh_direct_load_then_verification(self):
        result = self.execute(["run_idx_test", "idx_test_finish"], """
idx_test_find_persist_dir() { :; }
read_system_product_name() { echo iDX6011; }
idx_test_capture() { echo fixture; }
idx_test_backup() { echo backup >> "$CALLS"; }
idx_test_prepare_install() { echo prepare >> "$CALLS"; }
bash() { printf 'install:%s\\n' "$*" >> "$CALLS"; }
idx_test_load_cached_module() { echo load >> "$CALLS"; IDX_TEST_MODULE_LOADED_FROM_CACHE=true; }
idx_test_verify() { echo verify >> "$CALLS"; test "$IDX_TEST_MODULE_LOADED_FROM_CACHE" = true; }
run_idx_test
""")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls[:2], ["backup", "prepare"])
        self.assertIn("--controller-source idx6011", calls[2])
        self.assertNotIn("--force", calls[2])
        self.assertEqual(calls[3:], ["load", "verify"])
        report = next(self.persist.parent.glob("ugreen-idx-test-*/feedback.md"))
        self.assertIn("TECHNICAL PASS", report.read_text())
        self.assertIn("SUCCESS:", result.stdout)

    def test_verification_requires_explicit_module_identity(self):
        env = self.verification_fixture()
        env["IDX_TEST_MODULE_LOADED_FROM_CACHE"] = "false"
        result = self.execute(["idx_test_verify"], "idx_test_verify", **env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("identity was not established", result.stdout)

    def test_verification_rejects_missing_led_and_loaded_binary_mismatch(self):
        env = self.verification_fixture()
        self.write("sys/module/led_ugreen/srcversion", "old-fork")
        result = self.execute(["idx_test_verify"], "idx_test_verify", **env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stdout)
        self.write("sys/module/led_ugreen/srcversion", "fixture")
        (self.host / "sys/class/leds/disk6").rmdir()
        result = self.execute(["idx_test_verify"], "idx_test_verify", **env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LED missing: disk6", result.stdout)

    def test_power_service_is_required_only_when_configured(self):
        env = self.verification_fixture()
        self.stub("systemctl", '[[ "$*" != *ugreen-power-led* ]]')
        for power_mode in ("none", "oneshot"):
            with self.subTest(power_mode=power_mode):
                (self.persist / "ugreen-leds.conf").write_text("BLINK_TYPE_POWER=" + power_mode + "\n")
                result = self.execute(["idx_test_verify"], "idx_test_verify", **env)
                self.assertEqual(result.returncode == 0, power_mode == "none", result.stdout + result.stderr)

    def test_feedback_write_failure_never_reports_success(self):
        (self.run / "before.txt").write_text("before fixture")
        (self.run / "feedback.md").mkdir()
        result = self.execute(["idx_test_finish"], 'idx_test_capture() { echo after; }; idx_test_finish 0', IDX_TEST_RESULT="TECHNICAL PASS")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not write", result.stderr)
        self.assertNotIn("SUCCESS:", result.stdout)

    def test_success_report_still_requires_physical_observations(self):
        (self.run / "before.txt").write_text("before fixture")
        result = self.execute(["idx_test_finish"], 'idx_test_capture() { echo after; }; idx_test_finish 0', IDX_TEST_RESULT="TECHNICAL PASS")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.run / "feedback.md").read_text()
        self.assertIn("NOT verified automatically", report)
        self.assertIn("Disk LEDs correspond to bays", report)
        self.assertIn("SUCCESS:", result.stdout)
        self.assertIn(str(self.run / "feedback.md"), result.stdout)


if __name__ == "__main__":
    unittest.main()
