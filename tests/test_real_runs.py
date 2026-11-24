"""Full installer runs on a fake host. Real rm and cp run only inside a temp dir."""
import itertools
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from test_installer import FIXTURES, SOURCE

# The lookbehind leaves the unit-file sed pattern alone: it must match the
# /usr/bin paths inside the fake clone, not the remapped host path.
HOST_PATH = re.compile(r"(?<!s\|)/(?=(?:etc|sys|usr|lib|mnt)/)")
OWNED_FILES = re.search(r"^readonly PERSIST_FILES=\((.*)\)$", SOURCE, re.M).group(1).split()
ARTIFACT_COMMIT = re.search(r'^readonly IDX_ARTIFACT_COMMIT="(\w+)"$', SOURCE, re.M).group(1)
# Probes also pass --output; only the module download gets this longer limit.
DOWNLOAD = "--max-time 120"
SCRIPTS_COMMIT = re.search(r'^readonly IDX_UPSTREAM_COMMIT="(\w+)"$', SOURCE, re.M).group(1)
SWAP_NEW = ".ugreen_leds_controller.swap-new"
SWAP_OLD = ".ugreen_leds_controller.swap-old"
# Real modinfo reads a path as a module file only when the name ends in .ko.
MODINFO = '[[ "${!#}" == *.ko ]] || exit 1\n'
BETA_MODINFO = MODINFO + 'if [[ "$1" == -F ]]; then echo test; else printf "parm: %s:x\\n" write_protocol num_netdev_leds num_disk_leds; fi'


class FakeHost:
    """Temp tree standing in for the TrueNAS root, with host commands stubbed."""

    def __init__(self, script_dir="mnt/tank/scripts"):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.tree = self.root / "host"
        self.bin = self.root / "bin"
        self.clone = self.root / "clone"
        self.calls = self.root / "calls"
        self.mounts = self.root / "mounts"
        self.persist = self.tree / "mnt/tank/apps/leds_controller"
        self.bin.mkdir()
        self.calls.touch()
        self.mounts.touch()
        for path in ["etc/modules-load.d", "etc/systemd/system/multi-user.target.wants", "sys/class/dmi/id",
                     "usr/bin", "lib/modules/test/extra", "mnt/tank/apps", script_dir]:
            (self.tree / path).mkdir(parents=True, exist_ok=True)
        (self.tree / "etc/version").write_text("25.10.5\n")
        (self.tree / "sys/class/dmi/id/product_name").write_text("DXP8800 Plus\n")
        for command in ["modprobe", "insmod", "rmmod", "depmod", "nano"]:
            self.stub(command, f'echo "{command} $*" >> "$CALLS"')
        self.stub("uname", "echo test")
        self.stub("modinfo", MODINFO + "echo fixture")
        self.stub("mount", 'if (( $# )); then echo "mount $*" >> "$CALLS"; else cat "$MOUNTS"; fi')
        self.stub("systemctl", '''
echo "systemctl $*" >> "$CALLS"
case "$1" in
    cat) cat "$HOST/etc/systemd/system/$2" 2>/dev/null ;;
    is-active) [[ -n "${ACTIVE:-}" ]]; exit ;;
    is-enabled) [[ -n "${ACTIVE:-}" ]]; exit ;;
    show) echo active ;;
esac
exit 0''')
        self.stub("curl", '''
echo "curl $*" >> "$CALLS"
[[ -z "${OFFLINE:-}" ]] || exit 7
[[ "$*" != *--fail*"/${MISSING:-none}?ref"* ]] || exit 22
if [[ "$*" == *--head* ]]; then
    case "$*" in
        *"/${MISSING:-none}/"*) printf 404 ;;
        *"/${BROKEN:-none}/"*) printf 503 ;;
        *) printf 200 ;;
    esac
    exit 0
fi
if [[ "$*" == *--output* ]]; then
    [[ -z "${FAIL_DOWNLOAD:-}" ]] || exit 22
    while (( $# )); do [[ "$1" == --output ]] && echo ko > "$2"; shift; done
    exit 0
fi
printf '{"name":"TrueNAS-SCALE-Goldeye"}\\n\'''')
        self.stub("git", '''
[[ -z "${OFFLINE:-}" ]] || exit 128
[[ "$*" != *rev-parse* ]] || echo "${HEAD_COMMIT:-}"
if [[ "$1" == clone ]]; then
    echo "git clone" >> "$CALLS"
    for arg; do [[ "$arg" == "$HOST"/* ]] && target="$arg"; done
    if [[ -n "${FAIL_GIT:-}" ]]; then mkdir "$target"; exit 128; fi
    cp -r "$CLONE" "$target"
    mkdir "$target/.git"
fi''')
        self.build_clone()
        self.script = self.tree / script_dir / "install_ugreen_leds_controller.sh"
        # The boot-pool path is built at runtime, so the regex cannot see it.
        self.script.write_text(HOST_PATH.sub(str(self.tree) + "/", SOURCE).replace("${EUID:-0}", "0")
                               .replace('"/${BOOT_POOL_PATH}', f'"{self.tree}/${{BOOT_POOL_PATH}}'))

    def build_clone(self):
        scripts = self.clone / "scripts"
        (scripts / "systemd").mkdir(parents=True)
        for name in ["ugreen-diskiomon", "ugreen-probe-leds"]:
            shutil.copy(FIXTURES / name, scripts)
        for name in ["ugreen-netdevmon", "ugreen-netdevmon-multi", "ugreen-power-led"]:
            (scripts / name).write_text("#!/bin/bash\n")
        for unit, command in {"ugreen-diskiomon": "ugreen-diskiomon", "ugreen-probe-leds": "ugreen-probe-leds",
                              "ugreen-netdevmon-multi": "ugreen-netdevmon-multi", "ugreen-power-led": "ugreen-power-led",
                              "ugreen-netdevmon@": "ugreen-netdevmon %i"}.items():
            (scripts / "systemd" / f"{unit}.service").write_text(f"[Service]\nExecStart=/usr/bin/{command}\n")
        # Exactly as upstream writes it, quotes included.
        (scripts / "ugreen-leds.conf").write_text('BLINK_TYPE_POWER="none"\n')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def unit(self, name):
        return (self.tree / "etc/systemd/system" / name).read_text()

    def take_calls(self):
        calls = self.calls.read_text()
        self.calls.write_text("")
        return calls

    def paths(self):
        return {str(path.relative_to(self.tree)) for path in self.tree.rglob("*")}

    def fail_systemctl(self, command, action="exit 1"):
        path = self.bin / "systemctl"
        path.write_text(path.read_text().replace("#!/bin/bash\n", f'#!/bin/bash\n[[ "$*" != "{command}" ]] || {action}\n', 1))

    def env(self, **extra):
        return dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", CALLS=str(self.calls), HOST=str(self.tree),
                    CLONE=str(self.clone), MOUNTS=str(self.mounts), **extra)

    def run(self, *args, cwd=None, stdin="", **env):
        return subprocess.run(["bash", str(self.script), *args], cwd=cwd or self.tree / "mnt/tank/apps",
                              input=stdin, text=True, capture_output=True, env=self.env(**env), timeout=30)


class RealRunTests(unittest.TestCase):
    def host(self, **kwargs):
        host = FakeHost(**kwargs)
        self.addCleanup(host.tmp.cleanup)
        return host

    def init_command(self, result):
        return next(line for line in result.stdout.splitlines() if line.startswith('  /bin/bash "')).strip()

    def install(self, host, persist, *args, **env):
        result = host.run("--yes", "--persist-dir", str(persist), *args, **env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_uninstall_keeps_unrelated_files_in_shared_folder(self):
        host = self.host()
        shared = host.tree / "mnt/tank/apps"
        self.install(host, shared)
        for owned in ["ugreen_leds_controller", SWAP_NEW, SWAP_OLD]:
            (shared / owned / "scripts").mkdir(parents=True, exist_ok=True)
        (shared / ".led-ugreen.ko.download.abc123").write_text("partial")
        (shared / "family-photos.txt").write_text("irreplaceable")
        (shared / "scripts/my-own-script").write_text("keep me")

        result = host.run("--uninstall", "--yes", "--persist-dir", str(shared))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(p.name for p in shared.iterdir()), ["family-photos.txt", "scripts"])
        self.assertEqual([p.name for p in (shared / "scripts").iterdir()], ["my-own-script"])
        self.assertIn(f"Kept {shared}", result.stdout)

    def test_uninstall_removes_every_owned_file_and_the_emptied_folder(self):
        host = self.host()
        self.install(host, host.persist)
        for name in OWNED_FILES:
            (host.persist / name).touch()
        legacy_copy = host.tree / "usr/bin/ugreen-diskiomon"
        legacy_copy.write_text("from an older install")
        result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(host.persist.exists())
        self.assertFalse(legacy_copy.exists())
        self.assertFalse((host.tree / "etc/ugreen-leds.conf").exists())
        self.assertFalse((host.tree / "etc/modules-load.d/ugreen-led.conf").exists())
        self.assertEqual(list((host.tree / "etc/systemd/system").glob("ugreen-*")), [])
        self.assertIn("All UGREEN LEDs controller components have been removed.", result.stdout)

    def test_uninstall_killed_part_way_can_be_rerun_or_reinstalled(self):
        targets = {"config": "/leds_controller/ugreen-leds.conf", "helper": "/scripts/ugreen-diskiomon",
                   "clone": f"/{SWAP_OLD}", "version": "/leds_controller/.version"}
        for kind, target, then in itertools.product(("marked", "v2"), targets, ("uninstall", "install")):
            if kind == "v2" and target == "version" and then == "uninstall":
                continue  # Only the .version and module pair proves a v2 folder; one rm between them is accepted.
            with self.subTest(kind=kind, target=target, then=then):
                host = self.host()
                self.v2_install(host) if kind == "v2" else self.install(host, host.persist)
                # A kill during rm -rf leaves part of the tree, here the clone's scripts gone.
                host.stub("rm", f'if [[ "$*" == *"{targets[target]}" ]]; then /bin/rm -rf "${{!#}}/scripts"; kill -9 $PPID; exit 1; fi; exec /bin/rm "$@"')
                result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))
                self.assertEqual(result.returncode, -9, result.stdout + result.stderr)
                (host.bin / "rm").unlink()
                if then == "uninstall":
                    result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(host.persist.exists())
                else:
                    self.install(host, host.persist)
                    self.assertTrue((host.persist / "scripts/ugreen-diskiomon").exists())
                    self.assertTrue((host.tree / "etc/systemd/system/ugreen-diskiomon.service").exists())

    def test_uninstall_reports_a_stuck_leftover_clone_once(self):
        host = self.host()
        self.install(host, host.persist)
        leftover = host.persist / SWAP_OLD
        leftover.mkdir()
        host.stub("rm", f'[[ "$*" != *"/{SWAP_OLD}" ]] || exit 1; exec /bin/rm "$@"')
        result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count(f"could not remove {leftover}\n"), 1)
        self.assertEqual(result.stdout.count(f"  {leftover}\n"), 1)
        self.assertFalse((host.persist / "ugreen_leds_controller").exists())

    def test_install_removes_a_legacy_netdevmon_instance(self):
        host = self.host()
        template = host.tree / "etc/systemd/system/ugreen-netdevmon@.service"
        template.write_text("[Service]\n")
        link = host.tree / "etc/systemd/system/multi-user.target.wants/ugreen-netdevmon@enp1s0.service"
        link.symlink_to(template)
        self.install(host, host.persist)
        self.assertIn("systemctl stop ugreen-netdevmon@enp1s0.service", host.take_calls())
        self.assertFalse(link.is_symlink())

    def test_uninstall_stops_a_legacy_netdevmon_instance(self):
        host = self.host()
        self.install(host, host.persist)
        link = host.tree / "etc/systemd/system/multi-user.target.wants/ugreen-netdevmon@enp1s0.service"
        link.symlink_to(host.tree / "etc/systemd/system/ugreen-netdevmon@.service")
        host.take_calls()
        result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist), ACTIVE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("systemctl stop ugreen-netdevmon@enp1s0.service", host.take_calls())

    def test_uninstall_finishes_and_warns_when_system_files_cannot_be_removed(self):
        host = self.host()
        self.install(host, host.persist)
        module = host.tree / "lib/modules/test/extra/led-ugreen.ko"
        self.assertTrue(module.exists())
        host.mounts.write_text("fixture on /usr type zfs (ro,relatime)\n")
        host.stub("rm", 'for a; do [[ "$a" == */lib/modules/* ]] && exit 1; done; exec /bin/rm "$@"')

        result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("mount -o remount,rw", host.calls.read_text())
        self.assertTrue(host.calls.read_text().endswith("mount -o remount,ro /usr\n"))
        self.assertIn(f"Warning: could not remove {module}", result.stdout)
        self.assertTrue(module.exists())
        self.assertFalse(host.persist.exists())
        self.assertIn(f"left in place:\n  {module}", result.stdout)
        self.assertNotIn("All UGREEN LEDs", result.stdout)
        self.assertNotIn("Uninstall Complete!", result.stdout)

    def v2_install(self, host):
        """An install from before the markers: only the unit proves the folder."""
        self.install(host, host.persist)
        for marker in (".module-source", ".installer-source"):
            (host.persist / marker).unlink()

    def test_v2_clone_is_still_the_installers_after_an_update_removed_the_unit(self):
        host = self.host()
        self.v2_install(host)
        for unit in (host.tree / "etc/systemd/system").glob("ugreen-*"):
            unit.unlink()
        (host.tree / "etc/version").write_text("25.10.6\n")
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((host.tree / "etc/systemd/system/ugreen-diskiomon.service").exists())

    def test_uninstall_of_a_wrong_folder_keeps_the_only_proof_of_the_real_one(self):
        host = self.host()
        self.v2_install(host)
        unit = host.tree / "etc/systemd/system/ugreen-diskiomon.service"
        for wrong in (host.tree / "mnt/tank", host.tree / "mnt/tank/typo"):
            result = host.run("--uninstall", "--yes", "--persist-dir", str(wrong))
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn(f'--persist-dir "{host.persist}"', result.stderr)
            self.assertTrue(unit.exists())
        result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(host.persist.exists())

    def test_uninstall_dry_run_of_a_v2_install_changes_nothing(self):
        host = self.host()
        self.v2_install(host)
        before = host.paths()
        result = host.run("--uninstall", "--yes", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(host.paths(), before)

    def test_failed_daemon_reload_does_not_stop_the_uninstall(self):
        host = self.host()
        self.install(host, host.persist)
        (host.tree / "sys/module/led_ugreen").mkdir(parents=True)
        host.fail_systemctl("daemon-reload")
        host.take_calls()
        result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("rmmod led-ugreen", host.take_calls())
        self.assertFalse(host.persist.exists())
        self.assertIn("(daemon-reload failed)", result.stdout)
        self.assertNotIn("Reloaded systemd daemon", result.stdout)

    def test_uninstall_reads_an_unquoted_off_pool_unit(self):
        host = self.host()
        old = host.tree / "opt/leds_controller"
        old.mkdir(parents=True)
        (old / "led-ugreen.ko").write_text("ko")
        (host.tree / "etc/systemd/system/ugreen-diskiomon.service").write_text(
            f"[Service]\nExecStart={old}/scripts/ugreen-diskiomon\n")
        result = host.run("--uninstall", "--yes")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(old.exists())

    def test_uninstall_with_no_known_folder_creates_nothing_and_never_prompts(self):
        host = self.host()
        before = host.paths()
        result = host.run("--uninstall")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(host.paths(), before)
        self.assertNotIn("Persistent Storage Directory Selection", result.stdout)
        self.assertIn(f"Persistent directory {host.script.parent}/leds_controller not found", result.stdout)
        self.assertIn("rerun with --persist-dir", result.stdout)
        self.assertNotIn("All UGREEN LEDs", result.stdout)

    def test_declined_uninstall_prompt_keeps_files_and_says_so(self):
        host = self.host()
        self.install(host, host.persist)
        source = (host.persist / ".installer-source").read_text()
        result = host.run("--uninstall", "--persist-dir", str(host.persist), stdin="n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((host.persist / ".installer-source").read_text(), source)
        self.assertIn("Other files stay", result.stdout)
        self.assertTrue((host.persist / "led-ugreen.ko").exists())
        self.assertIn(f"{host.persist} (kept at your request)", result.stdout)
        self.assertNotIn("All UGREEN LEDs", result.stdout)

    def test_uninstall_on_closed_stdin_declines_and_still_prints_the_summary(self):
        host = self.host()
        self.install(host, host.persist)
        result = host.run("--uninstall", "--persist-dir", str(host.persist), stdin="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((host.persist / "led-ugreen.ko").exists())
        self.assertIn(f"{host.persist} (kept at your request)", result.stdout)

    def test_uninstall_stops_services_and_unloads_the_driver(self):
        host = self.host()
        self.install(host, host.persist)
        (host.tree / "sys/module/led_ugreen").mkdir(parents=True)
        host.take_calls()
        result = host.run("--uninstall", "--yes", ACTIVE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = host.take_calls().splitlines()
        for line in ("systemctl stop ugreen-diskiomon.service", "systemctl disable ugreen-diskiomon.service", "rmmod led-ugreen"):
            self.assertIn(line, calls)

    def test_uninstall_reports_a_driver_that_stays_loaded_but_not_a_shared_module(self):
        for name, stub, left in (("led_ugreen", "exit 1", True), ("i2c_dev", "exit 1", False)):
            with self.subTest(name=name):
                host = self.host()
                self.install(host, host.persist)
                (host.tree / "sys/module" / name).mkdir(parents=True)
                host.stub("rmmod", stub)
                result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual("led-ugreen module (still loaded)" in result.stdout, left)
                self.assertEqual("All UGREEN LEDs" in result.stdout, not left)

    def own_checkout(self, host):
        folder = host.tree / "mnt/tank/code"
        (folder / "ugreen_leds_controller/.git").mkdir(parents=True)
        (folder / "ugreen_leds_controller/unpushed.c").write_text("work")
        (folder / "ugreen-leds.conf").write_text("hand tuned\n")
        (folder / "scripts").mkdir()
        (folder / "scripts/ugreen-power-led").write_text("my fork\n")
        return folder

    def test_uninstall_leaves_a_folder_that_never_held_an_install(self):
        host = self.host()
        folder = self.own_checkout(host)
        empty = host.tree / "mnt/tank/empty"
        empty.mkdir()
        before = host.paths()
        for target in (folder, empty):
            with self.subTest(target=target):
                result = host.run("--uninstall", "--yes", "--persist-dir", str(target))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(host.paths(), before)
                self.assertIn(f"{target} (holds no installation, nothing removed)", result.stdout)
                self.assertNotIn("All UGREEN LEDs", result.stdout)

    def test_uninstall_does_not_delete_through_a_symlinked_scripts_folder(self):
        host = self.host()
        self.install(host, host.persist)
        own = host.tree / "mnt/tank/own-tools"
        own.mkdir()
        (own / "ugreen-power-led").write_text("mine")
        shutil.rmtree(host.persist / "scripts")
        (host.persist / "scripts").symlink_to(own)
        result = host.run("--uninstall", "--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((own / "ugreen-power-led").exists())
        self.assertIn(f"{host.persist}/scripts (symlink)", result.stdout)

    def test_install_refuses_to_replace_a_checkout_it_did_not_create(self):
        host = self.host()
        folder = self.own_checkout(host)
        (folder / ".version").write_text("mine\n")  # Install proof only beside its module.
        work = folder / "ugreen_leds_controller/unpushed.c"
        before = host.paths()
        result = host.run("--yes", "--persist-dir", str(folder))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("It may be your own work", result.stderr)
        self.assertEqual(host.paths(), before)
        self.assertEqual(host.take_calls().count("curl "), 0)
        result = host.run("--yes", "--dry-run", "--persist-dir", str(folder))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("a real install would stop here", result.stdout)
        self.install(host, folder, "--force")
        self.assertFalse(work.exists())

    def test_v2_install_with_a_leftover_clone_upgrades_and_keeps_its_configuration(self):
        for written_as in ("{}", "{}/."):  # v2.0.x wrote the path as typed.
            with self.subTest(written_as=written_as):
                host = self.host()
                self.v2_install(host)
                unit = host.tree / "etc/systemd/system/ugreen-diskiomon.service"
                unit.write_text(f"[Service]\nExecStart={written_as.format(host.persist)}/scripts/ugreen-diskiomon\n")
                (host.persist / "ugreen-leds.conf").write_text("MINE=1\n")
                (host.persist / ".version").unlink()  # Leaves only the unit to prove the folder.
                self.install(host, host.persist)
                self.assertEqual((host.persist / "ugreen-leds.conf").read_text(), "MINE=1\n")
                self.assertTrue((host.persist / ".module-source").exists())

    def test_clone_is_refused_when_the_unit_belongs_to_another_folder(self):
        host = self.host()
        self.install(host, host.persist)
        folder = self.own_checkout(host)
        result = host.run("--yes", "--persist-dir", str(folder))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("It may be your own work", result.stderr)

    def test_off_pool_yes_install_is_refused_before_any_change(self):
        host = self.host(script_dir="root")
        before = host.paths()
        for args in ((), ("--persist-dir", str(host.tree / "mnt/tank/../../etc/evil"))):
            with self.subTest(args=args):
                result = host.run("--yes", *args, cwd=host.tree / "root")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("must be under", result.stderr)
                self.assertEqual(host.paths(), before)
                self.assertNotIn("git clone", host.calls.read_text())

    def test_off_pool_dry_run_only_warns(self):
        host = self.host(script_dir="root")
        before = host.paths()
        result = host.run("--yes", "--dry-run", cwd=host.tree / "root")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("WARNING: persistent directory", result.stdout)
        self.assertEqual(host.paths(), before)

    def test_persist_dir_and_pool_path_work_from_outside_mnt(self):
        for args, persist in ((("--persist-dir", "{tree}/mnt/tank/apps/explicit"), "mnt/tank/apps/explicit"),
                              (("--pool-path", "tank/apps/pool"), "mnt/tank/apps/pool/leds_controller")):
            with self.subTest(args=args):
                host = self.host(script_dir="root")
                args = [arg.format(tree=host.tree) for arg in args]
                result = host.run("--yes", *args, cwd=host.tree / "root")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((host.tree / persist / "led-ugreen.ko").exists())

    def test_flag_with_missing_value_fails_clearly(self):
        host = self.host()
        for flag in ["-v", "--persist-dir", "--pool-path", "--controller-source"]:
            for rest in [(), ("--yes",), ("",)]:
                with self.subTest(flag=flag, rest=rest):
                    result = host.run(flag, *rest)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stderr, f"Option {flag} requires a value.\n")
                    self.assertEqual(result.stdout, "")
        self.assertEqual(host.calls.read_text(), "")

    def test_path_with_spaces_produces_quoted_units_and_uninstalls(self):
        host = self.host()
        persist = host.tree / "mnt/tank/my apps/leds_controller"
        result = host.run("--yes", "--pool-path", "tank/my apps")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'ExecStart="{persist}/scripts/ugreen-netdevmon" %i\n', host.unit("ugreen-netdevmon@.service"))
        self.assertIn(f'ExecStart="{persist}/scripts/ugreen-diskiomon"\n', host.unit("ugreen-diskiomon.service"))
        self.assertIn(f'KO_PATH="{persist}/led-ugreen.ko"', (persist / "scripts/ugreen-probe-leds").read_text())
        self.assertIn(f'"{persist}/install_ugreen_leds_controller.sh" --yes', result.stdout)

        result = host.run("--uninstall", "--yes")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(persist.exists())

    def test_unsafe_path_characters_are_refused_but_uninstall_still_works(self):
        for char in "\"'\\&|%$`\t":
            with self.subTest(char=char):
                host = self.host()
                persist = host.tree / f"mnt/tank/a{char}b"
                result = host.run("--yes", "--persist-dir", str(persist))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("must not contain", result.stderr)
                self.assertFalse(persist.exists())
        persist.mkdir()
        (persist / ".module-source").write_text("old")
        result = host.run("--uninstall", "--yes", "--persist-dir", str(persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(persist.exists())

    def test_non_ascii_path_installs_in_the_c_locale(self):
        host = self.host()
        persist = host.tree / "mnt/tank/münchen/leds_controller"
        result = host.run("--yes", "--persist-dir", str(persist), LC_ALL="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((persist / "led-ugreen.ko").exists())

    def test_idx_test_ignores_an_off_pool_unit(self):
        host = self.host()
        unit = host.tree / "etc/systemd/system/ugreen-diskiomon.service"
        for start, expected in ((f'"{host.persist}/scripts/ugreen-diskiomon"', f"using {host.persist}"),
                                ("/opt/leds_controller/scripts/ugreen-diskiomon", "No existing installation detected")):
            with self.subTest(start=start):
                unit.write_text(f"[Service]\nExecStart={start}\n")
                result = host.run("--idx-test", "collect", "--dry-run")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(expected, result.stdout)
        (host.script.parent / "led-ugreen.ko").touch()
        result = host.run("--idx-test", "collect", "--dry-run")
        self.assertIn(f"using {host.script.parent}", result.stdout)

    def test_idx_test_finds_the_install_in_the_current_folder(self):
        host = self.host(script_dir="root")
        host.persist.mkdir(parents=True)
        (host.persist / "led-ugreen.ko").touch()
        result = host.run("--idx-test", "collect", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"using {host.persist}", result.stdout)

    def test_idx_test_ignores_an_off_pool_module_it_only_guessed(self):
        for script_dir, cwd in (("opt/leds_controller", "opt/leds_controller"), ("root", "opt")):
            with self.subTest(script_dir=script_dir):
                host = self.host(script_dir=script_dir)
                module = host.tree / "opt/leds_controller/led-ugreen.ko"
                module.parent.mkdir(parents=True, exist_ok=True)
                module.touch()
                result = host.run("--idx-test", "collect", "--dry-run", cwd=host.tree / cwd)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("No existing installation detected", result.stdout)
                result = host.run("--idx-test", "install", "--dry-run", cwd=host.tree / cwd)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Add --persist-dir", result.stderr)

    def test_second_install_keeps_the_clone_and_stays_offline(self):
        host = self.host()
        self.install(host, host.persist)
        self.assertEqual(host.take_calls().count("git clone"), 1)
        sentinel = host.persist / "ugreen_leds_controller/sentinel"
        sentinel.touch()
        self.install(host, host.persist)
        calls = host.take_calls()
        self.assertNotIn("curl ", calls)
        self.assertNotIn("git clone", calls)
        self.assertTrue(sentinel.exists())

    def test_boot_with_the_driver_already_loaded_leaves_it_and_the_monitors_alone(self):
        host = self.host()
        self.install(host, host.persist)
        (host.tree / "sys/module/led_ugreen").mkdir(parents=True)
        host.take_calls()
        self.install(host, host.persist, ACTIVE="1")
        calls = host.take_calls()
        for call in ("rmmod ", "insmod ", "systemctl stop "):
            self.assertNotIn(call, calls)

    def test_clone_refreshes_for_update_force_marker_and_missing_clone(self):
        for change in ("update", "force", "marker", "missing"):
            with self.subTest(change=change):
                host = self.host()
                self.install(host, host.persist)
                clone = host.persist / "ugreen_leds_controller"
                marker = host.persist / ".installer-source"
                expected = marker.read_text()
                (clone / "sentinel").touch()
                if change == "update":
                    (host.tree / "etc/version").write_text("25.10.6\n")
                elif change == "marker":
                    marker.write_text("old\n")
                elif change == "missing":
                    shutil.rmtree(clone)
                host.take_calls()
                self.install(host, host.persist, *(["--force"] if change == "force" else []))
                self.assertEqual(host.take_calls().count("git clone"), 1)
                self.assertFalse((clone / "sentinel").exists())
                self.assertFalse((host.persist / SWAP_OLD).exists())
                self.assertEqual(marker.read_text(), expected)

    def test_offline_run_finishes_when_only_the_clone_step_fails(self):
        for change in ("missing clone", "missing marker"):
            with self.subTest(change=change):
                host = self.host()
                self.install(host, host.persist)
                if change == "missing clone":
                    shutil.rmtree(host.persist / "ugreen_leds_controller")
                else:
                    (host.persist / ".installer-source").unlink()
                host.take_calls()
                result = host.run("--yes", "--persist-dir", str(host.persist), OFFLINE="1")
                calls = host.take_calls()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Installation Complete!", result.stdout)
                self.assertIn(f"insmod {host.persist}/led-ugreen.ko", calls)
                self.assertIn("systemctl restart ugreen-diskiomon.service", calls)

    def test_offline_run_stops_when_the_clone_is_really_needed(self):
        def lost_script(host):
            (host.persist / "scripts/ugreen-diskiomon").unlink()

        def lost_unit(host):
            (host.tree / "etc/systemd/system/ugreen-diskiomon.service").unlink()

        for lose in (lost_script, lost_unit):
            with self.subTest(lose=lose.__name__):
                host = self.host()
                self.install(host, host.persist)
                shutil.rmtree(host.persist / "ugreen_leds_controller")
                lose(host)
                result = host.run("--yes", "--persist-dir", str(host.persist), OFFLINE="1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_force_resets_the_configuration(self):
        host = self.host()
        self.install(host, host.persist)
        configs = (host.persist / "ugreen-leds.conf", host.tree / "etc/ugreen-leds.conf")
        for config in configs:
            config.write_text("MINE=1\n")
        self.install(host, host.persist, "--force")
        for config in configs:
            self.assertNotIn("MINE", config.read_text())

    def test_force_needs_the_clone_even_offline(self):
        host = self.host()
        self.install(host, host.persist)
        result = host.run("--yes", "--force", "--persist-dir", str(host.persist), OFFLINE="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("left untouched", result.stderr)

    def test_next_clone_clears_what_a_run_killed_inside_the_swap_left(self):
        host = self.host()
        self.install(host, host.persist)
        # Left in place, this makes mv refuse to move the clone aside.
        (host.persist / SWAP_OLD / "ugreen_leds_controller/sentinel").mkdir(parents=True)
        self.install(host, host.persist, "--force")
        self.assertFalse((host.persist / SWAP_OLD).exists())

    def test_new_download_removes_files_a_killed_run_left(self):
        host = self.host()
        self.install(host, host.persist)
        stale = host.persist / ".led-ugreen.ko.download.abc123.ko"
        stale.write_text("partial")
        (host.tree / "etc/version").write_text("25.10.6\n")
        self.install(host, host.persist)
        self.assertFalse(stale.exists())

    def test_first_dry_run_previews_service_setup(self):
        host = self.host()
        result = host.run("--yes", "--dry-run", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("a real run would copy helper scripts", result.stdout)
        self.assertNotIn("skipping service setup", result.stdout)

    def test_printed_init_command_finds_the_same_install_offline(self):
        host = self.host()
        custom = host.tree / "mnt/tank/ugreen"
        result = host.run("--yes", "--persist-dir", str(custom), "-v", "25.10.4")
        command = self.init_command(result)
        self.assertEqual(command, f'/bin/bash "{custom}/install_ugreen_leds_controller.sh" --yes --persist-dir "{custom}" -v 25.10.4')
        self.assertIn("Remove -v 25.10.4", result.stdout)
        unit = host.unit("ugreen-diskiomon.service")
        (custom / "ugreen-leds.conf").write_text("MINE=1\n")
        (host.tree / "etc/ugreen-leds.conf").unlink()  # A TrueNAS update wipes /etc.
        host.take_calls()
        rerun = subprocess.run(["sh", "-c", command], cwd=host.root, text=True, capture_output=True,
                               timeout=30, env=host.env(OFFLINE="1"))
        self.assertEqual(rerun.returncode, 0, rerun.stdout + rerun.stderr)
        self.assertFalse((custom / "leds_controller").exists())
        self.assertEqual(host.unit("ugreen-diskiomon.service"), unit)
        self.assertEqual((host.tree / "etc/ugreen-leds.conf").read_text(), "MINE=1\n")
        self.assertEqual(host.take_calls().count("curl "), 0)

    def test_printed_init_command_for_the_default_folder_and_a_forced_source(self):
        script = 'leds_controller/install_ugreen_leds_controller.sh'
        host = self.host()
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(self.init_command(result), f'/bin/bash "{host.persist.parent}/{script}" --yes')
        result = host.run("--yes", "--persist-dir", str(host.persist), "--controller-source", "upstream")
        self.assertEqual(self.init_command(result), f'/bin/bash "{host.persist.parent}/{script}" --yes --controller-source upstream')

    def test_printed_init_command_uses_the_folder_the_script_sits_in(self):
        host = self.host()
        command = self.init_command(host.run("--yes", "--persist-dir", str(host.persist)))
        result = subprocess.run(["sh", "-c", command], cwd=host.root, text=True, capture_output=True,
                                timeout=30, env=host.env(OFFLINE="1"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((host.persist / "leds_controller").exists())

    def test_existing_folder_beside_the_script_wins_over_use_current_dir(self):
        host = self.host(script_dir="mnt/tank/apps")
        host.persist.mkdir()
        elsewhere = host.tree / "mnt/tank/elsewhere"
        elsewhere.mkdir()
        result = host.run("--yes", "--use-current-dir", cwd=elsewhere)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((host.persist / "led-ugreen.ko").exists())
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_failed_refresh_keeps_the_working_clone_and_marker(self):
        for failure, args, env in (("clone", (), {"FAIL_GIT": "1"}),
                                   ("verify", ("--controller-source", "idx6011"), {"HEAD_COMMIT": "wrong"})):
            with self.subTest(failure=failure):
                host = self.host()
                self.install(host, host.persist)
                sentinel = host.persist / "ugreen_leds_controller/sentinel"
                sentinel.touch()
                marker = host.persist / ".installer-source"
                expected = marker.read_text()
                (host.tree / "etc/version").write_text("25.10.6\n")
                result = host.run("--yes", "--persist-dir", str(host.persist), *args, **env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertTrue(sentinel.exists())
                self.assertFalse((host.persist / SWAP_NEW).exists())
                self.assertEqual(marker.read_text(), expected)
                self.assertIn("left untouched", result.stderr)
                self.assertNotIn("Installation Complete!", result.stdout)

    def test_optional_refresh_that_failed_keeps_the_installed_scripts(self):
        host = self.host()
        self.install(host, host.persist)
        installed = host.persist / "scripts/ugreen-power-led"
        installed.write_text("stable scripts")
        (host.clone / "scripts/ugreen-power-led").write_text("beta scripts")
        # The clone and its marker swap before the download fails, so the module stays stable.
        result = host.run("--yes", "--persist-dir", str(host.persist), "--controller-source", "idx6011",
                          FAIL_DOWNLOAD="1", HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((host.persist / "ugreen_leds_controller/scripts/ugreen-power-led").read_text(), "beta scripts")
        self.install(host, host.persist, OFFLINE="1")
        self.assertEqual(installed.read_text(), "stable scripts")
        self.install(host, host.persist)
        self.assertNotEqual(installed.read_text(), "stable scripts")

    def test_failed_module_load_stops_the_install(self):
        host = self.host()
        host.stub("insmod", "exit 1")
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("insmod could not load", result.stderr)
        self.assertNotIn("Installation Complete!", result.stdout)
        self.assertFalse((host.persist / ".version").exists())

    def test_failed_load_of_the_cached_module_does_not_block_the_next_offline_boot(self):
        host = self.host()
        self.install(host, host.persist)
        working = (host.bin / "insmod").read_text()
        host.stub("insmod", "exit 1")
        result = host.run("--yes", "--persist-dir", str(host.persist), OFFLINE="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        (host.bin / "insmod").write_text(working)
        self.install(host, host.persist, OFFLINE="1")

    def test_network_errors_never_pick_an_older_module(self):
        for args, env, retried, skipped in (((), {"BROKEN": "25.10.5"}, "/25.10.5/", "/25.10.4/"),
                                            ((), {"MISSING": "25.10.5", "BROKEN": "25.10.4"}, "/25.10.4/", "/25.10.3/"),
                                            (("--controller-source", "idx6011"), {"BROKEN": "25.10.5"}, "/25.10.5/", "/25.10.4/")):
            with self.subTest(args=args, env=env):
                host = self.host()
                result = host.run("--yes", "--persist-dir", str(host.persist), *args, **env)
                calls = host.take_calls()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Network error", result.stderr)
                self.assertNotIn("Kernel module not found", result.stdout + result.stderr)
                self.assertNotIn("kernel module not found", result.stdout + result.stderr)
                self.assertEqual(calls.count(retried), 2)
                self.assertNotIn(skipped, calls)
                self.assertNotIn(DOWNLOAD, calls)

    def test_fallback_that_loads_makes_no_network_calls_at_the_next_boot(self):
        host = self.host()
        result = host.run("--yes", "--persist-dir", str(host.persist), MISSING="25.10.5")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Using fallback kernel module", result.stdout)
        self.assertIn("/25.10.4/led-ugreen.ko", host.take_calls())
        self.assertEqual((host.persist / ".version").read_text(), "25.10.5\n")
        self.install(host, host.persist)
        self.assertNotIn("curl ", host.take_calls())

    def test_exact_module_prints_no_fallback_warning(self):
        host = self.host()
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Using fallback kernel module", result.stdout)

    def test_fallback_that_fails_to_load_is_retried_by_the_next_run(self):
        for version in ("25.10.5", "25.10.6"):
            with self.subTest(version=version):
                host = self.host()
                if version == "25.10.6":  # An update, with the old module to go back to.
                    self.install(host, host.persist)
                    (host.tree / "etc/version").write_text("25.10.6\n")
                working = (host.bin / "insmod").read_text()
                host.stub("insmod", "exit 1")
                result = host.run("--yes", "--persist-dir", str(host.persist), MISSING=version)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                (host.bin / "insmod").write_text(working)
                host.take_calls()
                self.install(host, host.persist)
                self.assertIn(f"/{version}/led-ugreen.ko", host.take_calls())
                self.assertEqual((host.persist / ".version").read_text(), f"{version}\n")

    def test_failed_download_or_validation_stops_and_keeps_the_cached_module(self):
        for failure, env, message in (("download", {"FAIL_DOWNLOAD": "1"}, "Kernel module download failed."),
                                      ("validation", {}, "Kernel module validation failed")):
            with self.subTest(failure=failure):
                host = self.swap_ready_host()
                (host.persist / "led-ugreen.ko").write_text("old")
                if failure == "validation":
                    host.stub("modinfo", "exit 1")
                result = host.run("--yes", "--persist-dir", str(host.persist), **env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual((host.persist / "led-ugreen.ko").read_text(), "old")
                self.assertEqual(list(host.persist.glob(".led-ugreen.ko.download.*")), [])

    def test_normal_boot_on_a_series_the_table_does_not_know_stays_offline(self):
        host = self.host()
        self.install(host, host.persist)
        (host.tree / "etc/version").write_text("26.04.1\n")
        (host.persist / ".version").write_text("26.04.1\n")
        host.take_calls()
        self.install(host, host.persist, OFFLINE="1")
        self.assertNotIn("curl ", host.take_calls())

    def test_unknown_series_stops_before_probing_any_module(self):
        host = self.host()
        (host.tree / "etc/version").write_text("26.04.1\n")
        result = host.run("--yes", "--persist-dir", str(host.persist), OFFLINE="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Unsupported TrueNAS SCALE version", result.stderr)
        self.assertIn("Warning: Could not fetch versions", result.stdout)
        self.assertNotIn("--head", host.take_calls())

    def swap_ready_host(self):
        host = self.host()
        self.install(host, host.persist)
        (host.tree / "sys/module/led_ugreen").mkdir(parents=True)
        (host.tree / "etc/version").write_text("25.10.6\n")
        host.take_calls()
        return host

    def test_stable_driver_swap_stops_services_first_and_restarts_them(self):
        host = self.swap_ready_host()
        self.install(host, host.persist, ACTIVE="1")
        calls = host.take_calls().splitlines()
        order = [calls.index(line) for line in ("systemctl stop ugreen-diskiomon.service", "rmmod led-ugreen",
                                                f"insmod {host.persist}/led-ugreen.ko",
                                                "systemctl restart ugreen-diskiomon.service")]
        self.assertEqual(order, sorted(order))
        for service in ("ugreen-netdevmon-multi", "ugreen-power-led"):
            self.assertIn(f"systemctl restart {service}.service", calls)
        self.assertFalse([line for line in calls if line.startswith("systemctl start ")])

    def test_failed_unload_keeps_the_markers_so_the_next_run_retries(self):
        host = self.swap_ready_host()
        (host.persist / "led-ugreen.ko").write_text("old")
        version = host.persist / ".version"
        host.stub("rmmod", "exit 1")
        for _ in range(2):
            result = host.run("--yes", "--persist-dir", str(host.persist), ACTIVE="1")
            calls = host.take_calls()
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("systemctl start ugreen-diskiomon.service --no-block", calls)
            self.assertNotIn("insmod ", calls)
            self.assertNotIn("Installation Complete!", result.stdout)
            self.assertEqual(version.read_text(), "25.10.5\n")
            self.assertEqual((host.persist / "led-ugreen.ko").read_text(), "old")
        host.stub("rmmod", 'echo "rmmod $*" >> "$CALLS"')
        self.install(host, host.persist)
        self.assertEqual(version.read_text(), "25.10.6\n")

    def test_failure_before_the_reload_leaves_the_running_driver_alone(self):
        host = self.swap_ready_host()
        (host.persist / "led-ugreen.ko").write_text("old")
        autoload = host.tree / "etc/modules-load.d/ugreen-led.conf"
        autoload.unlink()
        autoload.mkdir()
        result = host.run("--yes", "--persist-dir", str(host.persist))
        calls = host.take_calls()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("rmmod", calls)
        self.assertNotIn("insmod", calls)
        self.assertEqual((host.persist / "led-ugreen.ko").read_text(), "old")

    def test_failure_after_a_finished_swap_still_restarts_the_monitors(self):
        for failure in ("closed prompt", "daemon-reload"):
            with self.subTest(failure=failure):
                host = self.swap_ready_host()
                args = ["--persist-dir", str(host.persist)]
                if failure == "daemon-reload":
                    host.fail_systemctl(failure)
                    args.append("--yes")
                result = host.run(*args, ACTIVE="1")
                calls = host.take_calls().splitlines()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((host.persist / ".version").read_text(), "25.10.6\n")
                self.assertEqual(calls.count("rmmod led-ugreen"), 1)
                for service in ("diskiomon", "netdevmon-multi", "power-led", "probe-leds"):
                    self.assertIn(f"systemctl start ugreen-{service}.service --no-block", calls)

    def test_signal_before_the_monitor_restarts_still_starts_them(self):
        host = self.swap_ready_host()
        host.fail_systemctl("enable ugreen-diskiomon.service", "kill -TERM $PPID")
        result = host.run("--yes", "--persist-dir", str(host.persist), ACTIVE="1")
        calls = host.take_calls().splitlines()
        self.assertEqual(result.returncode, -15, result.stdout + result.stderr)
        for service in ("diskiomon", "netdevmon-multi", "power-led", "probe-leds"):
            self.assertIn(f"systemctl start ugreen-{service}.service --no-block", calls)

    def test_signal_during_cleanup_does_not_stop_it(self):
        host = self.swap_ready_host()
        host.mounts.write_text("fixture on /usr type zfs (ro,relatime)\n")
        host.fail_systemctl("daemon-reload")
        host.fail_systemctl("start ugreen-diskiomon.service --no-block", "{ kill -TERM $PPID; exit 1; }")
        result = host.run("--yes", "--persist-dir", str(host.persist), ACTIVE="1")
        calls = host.take_calls().splitlines()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("systemctl start ugreen-probe-leds.service --no-block", calls)
        self.assertEqual(calls[-1], "mount -o remount,ro /usr")

    def test_killed_swap_puts_the_old_module_back_before_the_next_download(self):
        host = self.swap_ready_host()
        module = host.persist / "led-ugreen.ko"
        previous = host.persist / "led-ugreen.ko.previous"
        module.write_text("bad new")
        previous.write_text("good old")
        self.assertEqual(host.run("--yes", "--dry-run", "--persist-dir", str(host.persist)).returncode, 0)
        self.assertEqual(previous.read_text(), "good old")
        host.stub("insmod", '[[ "$(cat "$1")" == "good old" ]]')
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(module.read_text(), "good old")
        self.assertFalse(previous.exists())

    def test_run_killed_before_the_marker_is_written_is_not_refused_next_time(self):
        host = self.host()
        host.stub("mv", '/bin/mv "$@"; [[ "$*" != *swap-new* ]] || kill -9 $PPID')
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, -9, result.stdout + result.stderr)
        host.stub("mv", 'exec /bin/mv "$@"')
        self.install(host, host.persist)

    def test_boot_after_a_kill_between_the_module_renames_uses_the_old_module(self):
        host = self.host()
        self.install(host, host.persist)
        module = host.persist / "led-ugreen.ko"
        previous = host.persist / "led-ugreen.ko.previous"
        module.write_text("good old")
        module.rename(previous)
        self.install(host, host.persist, OFFLINE="1")
        self.assertEqual(module.read_text(), "good old")
        self.assertFalse(previous.exists())

    def test_failed_swap_with_no_older_module_does_not_trust_the_new_one(self):
        host = self.swap_ready_host()
        (host.persist / "led-ugreen.ko").unlink()
        (host.persist / ".version").write_text("25.10.6\n")
        host.stub("insmod", "exit 1")
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse((host.persist / ".version").exists())

    def test_failed_stop_does_not_abandon_the_other_services(self):
        host = self.swap_ready_host()
        host.fail_systemctl("stop ugreen-netdevmon-multi.service")
        self.install(host, host.persist, ACTIVE="1")
        self.assertIn("systemctl restart ugreen-diskiomon.service", host.take_calls())

    def test_failed_monitor_start_does_not_stop_the_others(self):
        for action in ("enable", "restart"):
            with self.subTest(action=action):
                host = self.host()
                host.fail_systemctl(f"{action} ugreen-diskiomon.service")
                result = host.run("--yes", "--persist-dir", str(host.persist))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Installation Complete!", result.stdout)
                self.assertIn("systemctl restart ugreen-power-led.service", host.take_calls())

    def test_failed_new_module_brings_the_working_one_back(self):
        host = self.swap_ready_host()
        (host.persist / "led-ugreen.ko").write_text("old")
        parameters = host.tree / "sys/module/led_ugreen/parameters"
        parameters.mkdir()
        (parameters / "write_protocol").write_text("smbus-block\n")
        host.stub("insmod", 'echo "insmod $*" >> "$CALLS"; [[ "$(cat "$1")" == "old" ]]')
        result = host.run("--yes", "--persist-dir", str(host.persist), ACTIVE="1")
        calls = host.take_calls().splitlines()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("insmod could not load", result.stderr)
        module = host.persist / "led-ugreen.ko"
        self.assertLess(calls.index(f"insmod {module} write_protocol=smbus-block"), calls.index("systemctl start ugreen-diskiomon.service --no-block"))
        self.assertEqual(module.read_text(), "old")
        self.assertEqual((host.persist / ".version").read_text(), "25.10.5\n")
        self.assertFalse((host.persist / "led-ugreen.ko.previous").exists())

    def test_failed_new_module_on_an_unloaded_machine_keeps_the_old_one_cached(self):
        host = self.swap_ready_host()
        (host.tree / "sys/module/led_ugreen").rmdir()
        (host.persist / "led-ugreen.ko").write_text("old")
        host.stub("insmod", 'echo "insmod $*" >> "$CALLS"; [[ "$(cat "$1")" == "old" ]]')
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((host.persist / "led-ugreen.ko").read_text(), "old")
        self.assertIn(f"insmod {host.persist}/led-ugreen.ko", host.take_calls())

    def monitor(self, host):
        path = str(host.persist / "scripts/ugreen-netdevmon-multi")
        return subprocess.run(["bash", path], text=True, capture_output=True, timeout=10, env=host.env())

    def network_led(self, host, name="netdev"):
        led = host.tree / "sys/class/leds" / name
        led.mkdir(parents=True)
        for setting in ("trigger", "tx", "rx", "interval", "color", "brightness"):
            (led / setting).touch()
        return led

    def test_generated_network_monitor_fails_when_no_led_exists(self):
        host = self.host()
        self.install(host, host.persist)
        monitor = str(host.persist / "scripts/ugreen-netdevmon-multi")
        syntax = subprocess.run(["bash", "-n", monitor], text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        result = self.monitor(host)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("No network LEDs found", result.stdout)

    def test_generated_network_monitor_fails_when_any_led_write_fails(self):
        for setting in ("trigger", "interval", "brightness"):
            with self.subTest(setting=setting):
                host = self.host()
                self.install(host, host.persist)
                led = self.network_led(host)
                (led / setting).unlink()
                (led / setting).mkdir()  # Unwritable even when the tests run as root.
                result = self.monitor(host)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertNotIn("monitor started", result.stdout)

    def test_generated_network_monitor_fails_on_a_missing_override_led(self):
        host = self.host()
        self.install(host, host.persist)
        self.network_led(host)
        (host.tree / "etc/ugreen-leds.conf").write_text('NETDEV_LED_NAMES="netdev missing"\n')
        result = self.monitor(host)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Configured network LED not found: missing", result.stderr)
        self.assertIn("No network LEDs found", result.stdout)

    def test_generated_network_monitor_translates_the_old_idx_led_names(self):
        host = self.host()
        self.install(host, host.persist)
        (host.tree / "etc/ugreen-leds.conf").write_text('NETDEV_LED_NAMES="network_stat network_stat2"\n')
        self.network_led(host)
        self.network_led(host, "netdev2")
        host.stub("sleep", "kill $PPID")  # The monitor never exits on its own.
        result = self.monitor(host)
        self.assertIn("Network LEDs: netdev netdev2", result.stdout, result.stderr)

    def test_read_only_usr_is_restored_after_the_last_write(self):
        host = self.host()
        host.mounts.write_text("fixture on /usr type zfs (ro,relatime)\n")
        self.install(host, host.persist)
        calls = host.take_calls().splitlines()
        self.assertEqual([line for line in calls if line.startswith("mount ")],
                         ["mount -o remount,rw /usr", "mount -o remount,ro /usr"])
        self.assertLess(calls.index("mount -o remount,rw /usr"), calls.index("depmod -a"))
        # A kill cannot restore the mount, so the slow network steps run before it opens.
        download = next(i for i, line in enumerate(calls) if DOWNLOAD in line)
        self.assertLess(max(calls.index("git clone"), download), calls.index("mount -o remount,rw /usr"))
        self.assertEqual(calls[-1], "mount -o remount,ro /usr")

    def test_stacked_mount_is_judged_by_its_top_layer(self):
        for layers, expected in ((("ro", "rw"), []),
                                 (("rw", "ro"), ["mount -o remount,rw /usr", "mount -o remount,ro /usr"])):
            with self.subTest(layers=layers):
                host = self.host()
                host.mounts.write_text("".join(f"fixture on /usr type zfs ({layer},relatime)\n" for layer in layers))
                self.install(host, host.persist)
                self.assertEqual([line for line in host.take_calls().splitlines() if line.startswith("mount ")], expected)

    def test_read_only_etc_is_made_writable_and_put_back(self):
        host = self.host()
        etc = host.tree / "boot-pool/ROOT/25.10.5/etc"
        etc.mkdir(parents=True)
        host.mounts.write_text(f"fixture on {etc} type zfs (ro,relatime)\n")
        self.install(host, host.persist)
        self.assertEqual([line for line in host.take_calls().splitlines() if line.startswith("mount ")],
                         [f"mount -o remount,rw {etc}", f"mount -o remount,ro {etc}"])

    def test_failed_remount_is_not_undone(self):
        host = self.host()
        host.mounts.write_text("fixture on /usr type zfs (ro,relatime)\n")
        host.stub("mount", '''if (( $# )); then echo "mount $*" >> "$CALLS"; [[ "$*" != *,rw* ]] || exit 1
else cat "$MOUNTS"; fi''')
        self.install(host, host.persist)
        self.assertNotIn("remount,ro", host.take_calls())

    def test_failed_install_still_restores_read_only_usr(self):
        host = self.host()
        host.mounts.write_text("fixture on /usr type zfs (ro,relatime)\n")
        host.stub("insmod", "exit 1")
        result = host.run("--yes", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(host.take_calls().splitlines()[-1], "mount -o remount,ro /usr")

    def test_writable_usr_stays_as_found(self):
        host = self.host()
        host.mounts.write_text("fixture on /usr type zfs (rw,relatime)\n")
        self.install(host, host.persist)
        self.assertNotIn("mount ", host.take_calls())

    def test_install_leaves_usr_bin_alone_and_units_use_the_persistent_scripts(self):
        host = self.host()
        self.install(host, host.persist)
        self.assertEqual(list((host.tree / "usr/bin").iterdir()), [])
        self.assertIn(f'ExecStart="{host.persist}/scripts/ugreen-power-led"\n', host.unit("ugreen-power-led.service"))

    def test_power_led_service_starts_with_the_default_config(self):
        host = self.host()
        self.install(host, host.persist)
        calls = host.take_calls().splitlines()
        self.assertIn("systemctl enable ugreen-power-led.service", calls)
        self.assertIn("systemctl restart ugreen-power-led.service", calls)

    def test_module_urls_for_each_profile(self):
        tree = "miskcoo/ugreen_leds_controller"
        for args, raw, ref in (
                (("--controller-source", "idx6011"),
                 f"{ARTIFACT_COMMIT}/build-scripts/truenas/build/tags/v0.4-beta/TrueNAS-SCALE-Goldeye", ARTIFACT_COMMIT),
                ((), "refs/heads/gh-actions/build-scripts/truenas/build/TrueNAS-SCALE-Goldeye", "gh-actions")):
            with self.subTest(args=args):
                host = self.host()
                result = host.run("--yes", "--dry-run", "--persist-dir", str(host.persist), *args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"Module URL: https://raw.githubusercontent.com/{tree}/{raw}/25.10.5/led-ugreen.ko", result.stdout)
                api_calls = [line for line in host.take_calls().splitlines() if "api.github.com" in line]
                self.assertTrue(api_calls)
                self.assertTrue(all(f"?ref={ref}" in line for line in api_calls), api_calls)

    def test_old_beta_marker_downloads_the_pinned_module_once(self):
        host = self.host()
        host.persist.mkdir(parents=True)
        (host.persist / ".version").write_text("25.10.5\n")
        (host.persist / ".module-source").write_text(f"idx6011:{SCRIPTS_COMMIT}:gh-actions\n")
        (host.persist / "led-ugreen.ko").write_text("old")
        (host.tree / "sys/module/led_ugreen").mkdir(parents=True)
        host.stub("modinfo", BETA_MODINFO)
        args = ("--controller-source", "idx6011")
        self.install(host, host.persist, *args, HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(host.take_calls().count(DOWNLOAD), 1)
        self.assertIn(ARTIFACT_COMMIT, (host.persist / ".module-source").read_text())
        self.install(host, host.persist, *args, HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertNotIn("curl ", host.take_calls())

    def beta_host(self):
        host = self.host()
        (host.tree / "sys/class/dmi/id/product_name").write_text("iDX6011 Pro\n")
        host.stub("modinfo", BETA_MODINFO)
        return host

    def test_failed_probe_log_carries_no_hostname(self):
        host = self.beta_host()
        loaded = self.beta_parameters(host)
        args = ("--persist-dir", str(host.persist), "--controller-source", "idx6011")
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        host.take_calls()
        working = (host.bin / "systemctl").read_text()
        host.fail_systemctl("restart ugreen-probe-leds.service")
        host.stub("journalctl", 'prefix="Nov 01 10:00:00 my-nas "; [[ "$*" == *"-o cat"* ]] && prefix=""; echo "${prefix}probe failed"')
        result = host.run("--yes", *args, HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("probe failed", result.stdout)
        self.assertNotIn("my-nas", result.stdout)
        self.assertTrue(loaded.exists())
        # Nothing was downloaded, so the cached module stays trusted for an offline boot.
        self.assertTrue((host.persist / ".version").exists())
        (host.bin / "systemctl").write_text(working)
        self.install(host, host.persist, "--controller-source", "idx6011", OFFLINE="1", HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(host.take_calls().count(DOWNLOAD), 0)

    def beta_parameters(self, host):
        parameters = host.tree / "sys/module/led_ugreen/parameters"
        parameters.mkdir(parents=True)
        for name, value in (("write_protocol", "smbus-block"), ("num_netdev_leds", "2"), ("num_disk_leds", "6")):
            (parameters / name).write_text(value + "\n")
        return parameters

    def test_failed_beta_probe_restores_the_old_module_and_services(self):
        for failure in ("restart ugreen-probe-leds.service", "enable ugreen-probe-leds.service"):
            with self.subTest(failure=failure):
                host = self.beta_host()
                self.beta_parameters(host)
                self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                module = host.persist / "led-ugreen.ko"
                module.write_text("old beta")
                source = host.persist / ".module-source"
                source.write_text("old source\n")
                host.take_calls()
                host.fail_systemctl(failure)
                result = host.run("--yes", "--persist-dir", str(host.persist), "--controller-source", "idx6011",
                                  ACTIVE="1", HEAD_COMMIT=SCRIPTS_COMMIT)
                calls = host.take_calls()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"insmod {module} write_protocol=smbus-block num_netdev_leds=2 num_disk_leds=6", calls)
                self.assertIn("systemctl start ugreen-diskiomon.service --no-block", calls)
                self.assertEqual(module.read_text(), "old beta")
                # modprobe loads this copy at boot, so it must not stay the rejected module.
                self.assertEqual((host.tree / "lib/modules/test/extra/led-ugreen.ko").read_text(), "old beta")
                self.assertEqual(source.read_text(), "old source\n")

    def test_failed_beta_reload_without_a_download_puts_the_driver_back(self):
        host = self.beta_host()
        parameters = self.beta_parameters(host)
        args = ("--persist-dir", str(host.persist), "--controller-source", "idx6011")
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        (parameters / "write_protocol").write_text("legacy\n")
        host.take_calls()
        host.fail_systemctl("restart ugreen-probe-leds.service")
        result = host.run("--yes", *args, ACTIVE="1", HEAD_COMMIT=SCRIPTS_COMMIT)
        calls = host.take_calls().splitlines()
        module = host.persist / "led-ugreen.ko"
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        reload = f"insmod {module} write_protocol=legacy num_netdev_leds=2 num_disk_leds=6"
        self.assertLess(calls.index(reload), calls.index("systemctl start ugreen-diskiomon.service --no-block"))
        # The cached module is still good, so an offline boot must not need the network.
        self.assertEqual((host.persist / ".version").read_text(), "25.10.5\n")

    def test_failed_beta_swap_on_an_unloaded_machine_never_loads_it_without_parameters(self):
        for failure in ("probe failed", "wrong parameters"):
            with self.subTest(failure=failure):
                host = self.beta_host()
                self.beta_parameters(host)
                self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                shutil.rmtree(host.tree / "sys/module/led_ugreen")
                module = host.persist / "led-ugreen.ko"
                module.write_text("old beta")
                (host.persist / ".module-source").write_text("old source\n")
                if failure == "probe failed":
                    host.fail_systemctl("restart ugreen-probe-leds.service")
                else:
                    host.stub("depmod", 'mkdir -p "$HOST/sys/module/led_ugreen"')  # The new module appears.
                host.take_calls()
                result = host.run("--yes", "--persist-dir", str(host.persist), "--controller-source", "idx6011",
                                  HEAD_COMMIT=SCRIPTS_COMMIT)
                calls = host.take_calls()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertNotIn("insmod", calls)
                self.assertEqual("rmmod led-ugreen" in calls, failure == "wrong parameters")
                self.assertEqual(module.read_text(), "old beta")

    def test_failed_switch_to_stable_never_loads_the_beta_without_parameters(self):
        host = self.beta_host()
        self.beta_parameters(host)
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        shutil.rmtree(host.tree / "sys/module/led_ugreen")
        module = host.persist / "led-ugreen.ko"
        module.write_text("old beta")
        host.stub("insmod", 'echo "insmod $*" >> "$CALLS"; [[ "$(cat "$1")" == "old beta" ]]')
        host.take_calls()
        result = host.run("--yes", "--persist-dir", str(host.persist), "--controller-source", "upstream")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(host.take_calls().count("insmod "), 1)
        self.assertEqual(module.read_text(), "old beta")

    def test_idx_machine_on_the_old_fork_keeps_the_idx_profile_without_a_flag(self):
        fork = "idx6011:klein0r/ugreen_leds_controller@old:0x556c79/install_ugreen_leds_controller:idx6011-kmods\n"
        for product, stored, beta in (("iDX6011", fork, True), ("iDX6012", fork, True),
                                      ("iDX6011", "upstream:miskcoo/ugreen_leds_controller:gh-actions\n", False),
                                      ("DXP8800 Plus", fork, False)):
            with self.subTest(product=product, stored=stored):
                host = self.beta_host()
                self.beta_parameters(host)
                (host.tree / "sys/class/dmi/id/product_name").write_text(product + "\n")
                self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                (host.persist / ".module-source").write_text(stored)
                result = host.run("--yes", "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((host.persist / ".module-source").read_text().startswith("idx6011:miskcoo"), beta)
                self.assertEqual("--controller-source idx6011" in self.init_command(result), beta)

    def test_failed_module_lookup_still_starts_an_install_already_on_this_version(self):
        for args, starts in ((("--yes",), True), (("--yes", "--dry-run"), False)):
            with self.subTest(args=args):
                host = self.beta_host()
                self.beta_parameters(host)
                self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                (host.persist / ".module-source").write_text("idx6011:old fork\n")
                host.take_calls()
                result = host.run(*args, "--persist-dir", str(host.persist), MISSING="25.10.5", HEAD_COMMIT=SCRIPTS_COMMIT)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Exact upstream", result.stderr)
                self.assertEqual("systemctl start ugreen-diskiomon.service --no-block" in host.take_calls(), starts)

    def test_pro_beta_module_with_wrong_led_counts_fails_the_run(self):
        for name in ("num_netdev_leds", "num_disk_leds"):
            with self.subTest(name=name):
                host = self.beta_host()
                (self.beta_parameters(host) / name).write_text("-1\n")
                result = host.run("--yes", "--persist-dir", str(host.persist), "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("required parameters", result.stderr)

    def test_beta_module_with_the_legacy_protocol_fails_the_run(self):
        for model in ("iDX6011", "iDX6012", "DXP4800 GT"):
            with self.subTest(model=model):
                host = self.beta_host()
                (host.tree / "sys/class/dmi/id/product_name").write_text(model + "\n")
                (self.beta_parameters(host) / "write_protocol").write_text("legacy\n")
                result = host.run("--yes", "--persist-dir", str(host.persist), "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("required parameters", result.stderr)

    def test_beta_module_with_wrong_parameters_or_not_loaded_fails_the_run(self):
        for present, message in ((False, "completed without loading"), (True, "required parameters")):
            with self.subTest(present=present):
                host = self.beta_host()
                if present:
                    (host.tree / "sys/module/led_ugreen").mkdir(parents=True)
                result = host.run("--yes", "--persist-dir", str(host.persist), "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse((host.persist / ".version").exists())

    def idx_host(self):
        host = self.beta_host()
        for led in ("power", "netdev", "netdev2", "disk1", "disk2", "disk3", "disk4", "disk5", "disk6"):
            (host.tree / "sys/class/leds" / led).mkdir(parents=True)
        for command in ("sleep", "journalctl", "lsblk", "lspci", "i2cdetect", "depmod"):
            host.stub(command, ":")
        host.stub("findmnt", 'case "$*" in *OPTIONS*) echo rw;; *) echo /;; esac')
        host.stub("load-module", '''parameters="$HOST/sys/module/led_ugreen/parameters"
mkdir -p "$parameters"
echo smbus-block > "$parameters/write_protocol"
echo 2 > "$parameters/num_netdev_leds"
echo 6 > "$parameters/num_disk_leds"''')
        host.stub("insmod", 'echo "insmod $*" >> "$CALLS"; load-module')
        host.stub("rmmod", 'rm -r "$HOST/sys/module/led_ugreen"')
        host.stub("systemctl", '''echo "systemctl $*" >> "$CALLS"
case "$*" in
    list-unit-files*) echo "ugreen-diskiomon.service enabled enabled" ;;
    list-units*) echo "ugreen-diskiomon.service loaded active running x" ;;
    is-enabled*) exit 1 ;;
    "restart ugreen-probe-leds.service") load-module ;;
esac''')
        return host

    def rollback(self, host, returncode=0):
        script = next(host.tree.glob("mnt/tank/**/ugreen-idx-test-*/rollback.sh"))
        script.write_text(script.read_text().replace("${EUID}", "0"))
        result = subprocess.run(["bash", str(script)], text=True, capture_output=True, timeout=30, env=host.env())
        self.assertEqual(result.returncode, returncode, result.stdout + result.stderr)
        return result

    def test_idx_install_test_refreshes_the_old_install_and_recovery_restores_it(self):
        host = self.idx_host()
        # A rerun on the same beta: only the markers prepare removes can force the refresh.
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        (host.persist / "ugreen_leds_controller/old-checkout").touch()
        (host.persist / "led-ugreen.ko").write_text("old module")
        markers = {name: (host.persist / name).read_text() for name in
                   (".version", ".module-source", ".installer-source", "led-ugreen.ko")}
        host.take_calls()
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SUCCESS:", result.stdout)
        report = next(host.persist.parent.glob("ugreen-idx-test-*/feedback.md"))
        self.assertIn("TECHNICAL PASS", report.read_text())
        calls = host.take_calls()
        self.assertIn(DOWNLOAD, calls)
        self.assertIn("insmod " + str(host.persist / "led-ugreen.ko"), calls)
        self.assertFalse((host.persist / "ugreen_leds_controller/old-checkout").exists())
        (host.persist / "ugreen_leds_controller/beta-checkout").touch()

        for _ in range(2):  # A rerun after a failed recovery must keep the clone.
            self.rollback(host)
            self.assertIn("systemctl stop ugreen-diskiomon.service", host.take_calls())
            for name, value in markers.items():
                self.assertEqual((host.persist / name).read_text(), value, name)
            # The restored marker must not sit beside the beta checkout.
            self.assertFalse((host.persist / "ugreen_leds_controller/beta-checkout").exists())
            self.assertTrue((host.persist / "ugreen_leds_controller/old-checkout").exists())
        self.install(host, host.persist, "--controller-source", "idx6011", OFFLINE="1", HEAD_COMMIT=SCRIPTS_COMMIT)

    def test_idx_install_test_refuses_any_other_model(self):
        host = self.idx_host()
        (host.tree / "sys/class/dmi/id/product_name").write_text("DXP8800 Plus\n")
        (host.tree / "sys/module/led_ugreen").mkdir(parents=True)
        before = host.paths()
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("requires exact DMI", result.stderr)
        self.assertEqual(host.paths(), before)
        self.assertEqual(host.take_calls(), "")

    def test_new_idx_test_waits_for_the_rollback_of_the_last_one(self):
        host = self.idx_host()
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        arguments = ("--idx-test", "install", "--persist-dir", str(host.persist))
        self.assertEqual(host.run(*arguments, FAIL_GIT="1").returncode, 1)

        result = host.run(*arguments, HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("/rollback.sh", result.stderr)
        self.assertEqual(len(list(host.persist.parent.glob("ugreen-idx-test-*"))), 1)

        self.rollback(host)
        result = host.run(*arguments, HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_idx_report_hides_the_storage_path(self):
        host = self.idx_host()
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = next(host.persist.parent.glob("ugreen-idx-test-*/feedback.md")).read_text()
        self.assertNotIn("/mnt/", report)
        self.assertIn("<storage>/leds_controller", report)

    def test_idx_report_hides_a_path_outside_the_storage_folder(self):
        host = self.idx_host()
        host.stub("journalctl", f'echo "ExecStart={host.tree}/mnt/other/leds_controller/scripts/x"')
        result = host.run("--idx-test", "collect", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = next(host.persist.parent.glob("ugreen-idx-test-*/feedback.md")).read_text()
        self.assertIn("ExecStart=", report)
        self.assertNotIn("mnt/other", report)

    def test_idx_report_hides_an_off_pool_install_folder(self):
        for stage in ("collect", "install"):
            with self.subTest(stage=stage):
                host = self.idx_host()
                # A v2.0.x unit; the install stage rewrites it to the pool folder.
                unit = host.tree / "etc/systemd/system/ugreen-diskiomon.service"
                unit.write_text("[Service]\nExecStart=/opt/leds_controller/scripts/ugreen-diskiomon\n")
                host.fail_systemctl("cat ugreen-diskiomon.service", f'{{ cat "{unit}"; exit 0; }}')
                host.stub("journalctl", 'echo "ExecStart=/opt/leds_controller/scripts/ugreen-diskiomon"')
                result = host.run("--idx-test", stage, "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                report = next(host.persist.parent.glob("ugreen-idx-test-*/feedback.md")).read_text()
                self.assertIn("ExecStart=<storage>/scripts/ugreen-diskiomon", report)
                self.assertNotIn("/opt/", report)

    def test_idx_report_hides_a_pool_root_folder(self):
        host = self.idx_host()
        pool_root = host.tree / "mnt/tank"
        result = host.run("--idx-test", "collect", "--persist-dir", str(pool_root))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = next((host.tree / "mnt").glob("ugreen-idx-test-*/feedback.md")).read_text()
        self.assertNotIn("/tank", report)

    def test_failed_rollback_rerun_clears_the_rolled_back_marker(self):
        host = self.idx_host()
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), FAIL_GIT="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.rollback(host)
        script = next(host.persist.parent.glob("ugreen-idx-test-*/rollback.sh"))
        self.assertTrue(script.with_name("rolled-back").exists())

        host.stub("tar", "exit 1")
        result = subprocess.run(["bash", str(script)], text=True, capture_output=True, timeout=30, env=host.env())
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(script.with_name("rolled-back").exists())

    def test_recovery_with_a_busy_module_restarts_the_monitors_and_can_be_rerun(self):
        monitors = ("diskiomon", "netdevmon-multi", "power-led", "probe-leds")
        for case, returncode, active_before in (("passed test", 0, monitors), ("failed test", 1, monitors),
                                                ("first install", 0, ("diskiomon",))):
            with self.subTest(case=case):
                host = self.idx_host()
                old_clone = host.persist / "ugreen_leds_controller/old-checkout"
                if case != "first install":
                    self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                    old_clone.touch()
                working = (host.bin / "rmmod").read_text()
                if case == "failed test":
                    host.stub("rmmod", "exit 1")
                result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
                self.assertEqual(result.returncode, returncode, result.stdout + result.stderr)
                host.stub("rmmod", "exit 1")
                folder = next(host.persist.parent.glob("ugreen-idx-test-*"))
                if case == "first install":
                    (folder / "backup/active.txt").write_text("")  # Nothing ran before the test.
                host.take_calls()
                before = host.paths()

                self.assertIn("Module is busy", self.rollback(host, 1).stdout)
                self.assertEqual(host.paths(), before)
                calls = host.take_calls().splitlines()
                for monitor in active_before:
                    self.assertIn(f"systemctl start ugreen-{monitor}.service", calls)
                self.assertFalse((folder / "rolled-back").exists())
                self.assertFalse(old_clone.exists())

                (host.bin / "rmmod").write_text(working)
                self.rollback(host)
                self.assertTrue((folder / "rolled-back").exists())
                self.assertEqual(old_clone.exists(), case != "first install")

    def test_busy_recovery_starts_every_monitor_even_when_one_fails(self):
        host = self.idx_host()
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        host.stub("rmmod", "exit 1")
        host.fail_systemctl("start ugreen-diskiomon.service")
        host.take_calls()
        self.assertIn("Module is busy", self.rollback(host, 1).stdout)
        self.assertIn("systemctl start ugreen-power-led.service", host.take_calls())

    def test_failed_direct_load_fails_the_idx_test(self):
        for command in ("rmmod", "insmod"):
            with self.subTest(command=command):
                host = self.idx_host()
                host.stub(command, "exit 9")
                result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
                self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
                self.assertIn("FAILED:", result.stdout)
                self.assertNotIn("SUCCESS:", result.stdout)

    def test_idx_test_prints_the_recovery_command_before_the_install(self):
        host = self.idx_host()
        host.stub("git", 'kill -9 $PPID $(ps -o ppid= $PPID)')
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, -9, result.stdout + result.stderr)
        self.assertIn("recover with: sudo bash", result.stdout)

    def test_failed_idx_test_recovery_keeps_the_clone(self):
        host = self.idx_host()
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        (host.persist / "ugreen_leds_controller/old-checkout").touch()
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), FAIL_GIT="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAILED:", result.stdout)
        script = next(host.persist.parent.glob("ugreen-idx-test-*/rollback.sh"))
        self.assertIn(f"recover with: sudo bash {script}\n", result.stdout)
        self.rollback(host)
        self.assertTrue((host.persist / "ugreen_leds_controller/old-checkout").exists())

    def test_idx_test_that_stops_before_the_install_keeps_the_clone_through_recovery(self):
        for case in ("install", "own checkout"):
            with self.subTest(case=case):
                host = self.idx_host()
                if case == "install":
                    self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
                    folder = host.persist
                    work = folder / "ugreen_leds_controller/old-checkout"
                    work.touch()
                else:
                    folder = self.own_checkout(host)
                    work = folder / "ugreen_leds_controller/unpushed.c"
                    (folder / "led-ugreen.ko").write_text("ko")
                    (host.tree / "sys/module/led_ugreen").mkdir(parents=True)
                working = (host.bin / "rmmod").read_text()
                host.stub("rmmod", "exit 1")
                result = host.run("--idx-test", "install", "--persist-dir", str(folder))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Recovery command:", result.stdout)
                (host.bin / "rmmod").write_text(working)
                self.rollback(host)
                self.assertTrue(work.exists())

    def test_idx_test_offers_no_recovery_when_the_clone_cannot_be_saved(self):
        host = self.idx_host()
        self.install(host, host.persist, "--controller-source", "idx6011", HEAD_COMMIT=SCRIPTS_COMMIT)
        work = host.persist / "ugreen_leds_controller/old-checkout"
        work.touch()
        host.stub("mv", 'for a; do [[ "$a" != */backup/ugreen_leds_controller ]] || exit 1; done; exec /bin/mv "$@"')
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("Recovery command:", result.stdout)
        self.assertTrue(work.exists())
        self.assertTrue((host.tree / "sys/module/led_ugreen").exists())

    def test_recovery_after_a_first_install_leaves_no_unit_or_empty_folder(self):
        host = self.idx_host()
        result = host.run("--idx-test", "install", "--persist-dir", str(host.persist), HEAD_COMMIT=SCRIPTS_COMMIT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((host.tree / "etc/systemd/system/ugreen-netdevmon@.service").exists())
        self.rollback(host)
        self.assertEqual(list((host.tree / "etc/systemd/system").glob("ugreen-*")), [])
        self.assertFalse((host.persist / "scripts").exists())


if __name__ == "__main__":
    unittest.main()
