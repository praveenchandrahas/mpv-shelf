"""install-shelf.sh in a throwaway HOME: install, idempotency, stray-number cleanup, user options kept, remove."""
import os, subprocess, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "install-shelf.sh"


class Install(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.home = Path(self.td.name)
        self.env = {"HOME": str(self.home), "PATH": os.environ["PATH"]}

    def tearDown(self):
        self.td.cleanup()

    def run_(self, *a):
        return subprocess.run(["bash", str(SCRIPT), *a], env=self.env, capture_output=True, text=True)

    def test_install_and_idempotent(self):
        r = self.run_()
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg = self.home / ".config" / "mpv"
        self.assertTrue((cfg / "scripts" / "shelf.lua").exists())
        self.assertTrue((self.home / ".local/bin/shelf-index").stat().st_mode & 0o100)
        inp = (cfg / "input.conf").read_text()
        self.assertEqual(inp.count("Ctrl+b script-binding shelf/open"), 1)
        self.assertFalse((self.home / ".config/mpv-object-audio").exists())     # only if it was there already
        again = self.run_()
        self.assertEqual(again.returncode, 0)
        self.assertEqual((cfg / "input.conf").read_text(), inp)

    def test_atmos_config_dir_used_when_present(self):
        (self.home / ".config/mpv-object-audio").mkdir(parents=True)
        self.run_()
        self.assertTrue((self.home / ".config/mpv-object-audio/scripts/shelf.lua").exists())
        self.assertIn("shelf/open", (self.home / ".config/mpv-object-audio/input.conf").read_text())

    def test_existing_input_conf_kept_and_stray_numbers_removed(self):
        cfg = self.home / ".config/mpv"
        cfg.mkdir(parents=True)
        (cfg / "input.conf").write_text("42\nCtrl+x show-text hi\n7\n")
        self.run_()
        txt = (cfg / "input.conf").read_text()
        self.assertIn("Ctrl+x show-text hi", txt)
        self.assertNotIn("\n42\n", "\n" + txt)
        self.assertNotIn("\n7\n", "\n" + txt)
        self.assertIn("shelf/open", txt)

    def test_conflicting_key_is_not_overwritten(self):
        cfg = self.home / ".config/mpv"
        cfg.mkdir(parents=True)
        (cfg / "input.conf").write_text("Ctrl+b show-text mine\n")
        r = self.run_()
        self.assertEqual(r.returncode, 0)
        self.assertEqual((cfg / "input.conf").read_text(), "Ctrl+b show-text mine\n")
        self.assertIn("already binds", r.stderr)

    def test_user_options_survive_reinstall(self):
        self.run_()
        conf = self.home / ".config/mpv/script-opts/shelf.conf"
        conf.write_text("cols=5\n")
        self.run_()
        self.assertEqual(conf.read_text(), "cols=5\n")

    def test_remove(self):
        self.run_()
        data = self.home / ".local/share/mpv-shelf"
        data.mkdir(parents=True)
        (data / "history.json").write_text("{}")
        r = self.run_("remove")
        self.assertEqual(r.returncode, 0)
        cfg = self.home / ".config/mpv"
        self.assertFalse((cfg / "scripts/shelf.lua").exists())
        self.assertNotIn("shelf", (cfg / "input.conf").read_text())
        self.assertFalse((self.home / ".local/bin/shelf-index").exists())
        self.assertTrue((data / "history.json").exists())

    def test_touches_nothing_outside_home(self):
        before = set(Path("/etc").iterdir())
        self.run_()
        self.assertEqual(before, set(Path("/etc").iterdir()))

    def test_bad_argument(self):
        self.assertEqual(self.run_("--nope").returncode, 2)


if __name__ == "__main__":
    unittest.main()
