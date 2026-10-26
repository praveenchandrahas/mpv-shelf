"""Tests for shelf-index. Real release names (from the owner's library), a throwaway library of empty-ish files, and a fake network."""
import importlib.machinery, importlib.util, io, json, os, sys, tempfile, time, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("shelf_index", str(ROOT / "shelf-index"))
spec = importlib.util.spec_from_loader("shelf_index", loader)
si = importlib.util.module_from_spec(spec)
loader.exec_module(si)

REAL = [
    "Avatar.Fire.and.Ash.2025.2160p.UHD.BluRay.REMUX.HDR10Plus.DV.TrueHD.Atmos.7.1.HEVC-GRP.mkv",
    "Avatar Fire and Ash (2025) 2160p WEB-DL DDP5.1 Atmos DV HDR10+ HEVC-GRP2.mkv",
    "Avatar.Fire.and.Ash.2025.1080p.BluRay.x264-GRP3.mkv",
    "www.UIndex.org    -    Hope.2026.1080p.WEB-DL.DDP5.1.H.264-GRP.mkv",
    "Hopeu - Hope (2026)CZtit 1080p.mkv",
    "PROJECT_HAIL_MARY (2026) 4k HDR10+ DV WEB-DL.mkv",
    "The.Imitation.Game.2014.2160p.UHD.BluRay.REMUX.mkv",
    "IMAX Space Station.mkv",
    "Show.Name.2019.S02E05.1080p.WEB-DL.mkv",
]


class Parse(unittest.TestCase):
    def p(self, name):
        return si.parse_name(os.path.splitext(name)[0])

    def test_avatar_three_releases_share_one_key(self):
        keys = {(self.p(n)["key"], self.p(n)["year"]) for n in REAL[:3]}
        self.assertEqual(keys, {("avatar fire and ash", 2025)})

    def test_site_tag_removed(self):
        i = self.p(REAL[3])
        self.assertEqual((i["key"], i["year"]), ("hope", 2026))

    def test_hopeu_hope_is_a_different_film(self):
        self.assertNotEqual(self.p(REAL[4])["key"], self.p(REAL[3])["key"])

    def test_underscores_and_case(self):
        self.assertEqual(self.p(REAL[5])["title"], "Project Hail Mary")

    def test_chips(self):
        c = self.p(REAL[0])["chips"]
        for want in ("4K", "REMUX", "Atmos", "TrueHD"):
            self.assertIn(want, c)

    def test_no_year(self):
        i = self.p(REAL[7])
        self.assertIsNone(i["year"])
        self.assertEqual(i["key"], "imax space station")

    def test_episode(self):
        i = self.p(REAL[8])
        self.assertEqual((i["kind"], i["season"], i["episode"], i["key"]), ("episode", 2, 5, "show name"))

    def test_imdb_from_folder(self):
        i = si.parse_name("It.Ends.2025.2160p.WEB-DL.DDP5.1.HEVC", "It Ends [tt35519455]")
        self.assertEqual(i["imdb"], "tt35519455")


class Catalog(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.lib = Path(self.td.name) / "lib"
        self.lib.mkdir()
        for n in REAL:
            (self.lib / n).write_bytes(b"x" * 2000)
        (self.lib / "junk.iso").write_bytes(b"x" * 5000)
        (self.lib / "archive.part1.rar").write_bytes(b"x" * 5000)
        (self.lib / "sub").mkdir()
        (self.lib / "sub" / "Hope.2026.720p.mkv").write_bytes(b"x" * 100)
        self.files = si.list_library(str(self.lib), 0)

    def tearDown(self):
        self.td.cleanup()

    def test_only_video_files(self):
        names = [os.path.basename(f[0]) for f in self.files]
        self.assertNotIn("junk.iso", names)
        self.assertNotIn("archive.part1.rar", names)

    def test_min_size(self):
        small = si.list_library(str(self.lib), 1000)
        self.assertNotIn("sub/Hope.2026.720p.mkv", [f[0] for f in small])

    def test_grouping(self):
        es = si.build_catalog(self.files)
        films = {e["key"]: e for e in es if e["kind"] == "film"}
        self.assertEqual(len(films["avatar fire and ash"]["releases"]), 3)
        self.assertEqual(len(films["hope"]["releases"]), 2)      # the UIndex file and sub/Hope.2026.720p
        # best first: 2160 REMUX leads
        self.assertIn("REMUX", films["avatar fire and ash"]["releases"][0]["chips"])
        shows = [e for e in es if e["kind"] == "show"]
        self.assertEqual(len(shows), 1)
        self.assertEqual(list(shows[0]["seasons"]), ["2"])

    def test_yearless_never_grouped(self):
        (self.lib / "IMAX Space Station (copy).mkv").write_bytes(b"x" * 100)
        es = si.build_catalog(si.list_library(str(self.lib), 0))
        self.assertEqual(len([e for e in es if e["kind"] == "film" and e["key"].startswith("imax space station")]), 2)

    def test_ids_stable_and_unique(self):
        a = si.build_catalog(self.files)
        b = si.build_catalog(self.files)
        self.assertEqual([e["id"] for e in a], [e["id"] for e in b])
        self.assertEqual(len({e["id"] for e in a}), len(a))

    def test_plan_output(self):
        out = io.StringIO()
        rc = si.cmd_plan({"library": str(self.lib), "min_size_mb": 0}, out)
        self.assertEqual(rc, 0)
        self.assertIn("Avatar Fire And Ash".lower(), out.getvalue().lower())
        self.assertIn("3 releases share", out.getvalue())

    def test_plan_missing_library(self):
        rc = si.cmd_plan({"library": str(self.lib / "nope"), "min_size_mb": 0}, io.StringIO())
        self.assertEqual(rc, 1)


class FakeNet:
    """Stands in for TMDB and the image server."""
    def __init__(self):
        self.calls = []
        self.status = 200

    def __call__(self, url, headers=None, timeout=15):
        self.calls.append(url)
        if self.status != 200:
            return self.status, b"", {"Retry-After": "0"}
        if "image.tmdb.org" in url:
            return 200, b"\xff\xd8\xff\xe0not-really-a-jpeg", {}
        if "/find/" in url:
            return 200, json.dumps({"movie_results": [{"id": 7, "title": "It Ends", "release_date": "2025-05-01", "vote_average": 6.04,
                                                       "overview": "o", "poster_path": "/p.jpg"}], "tv_results": []}).encode(), {}
        if "/search/movie" in url:
            q = url.lower()
            if "avatar" in q:
                return 200, json.dumps({"results": [{"id": 1, "title": "Avatar: Fire and Ash", "release_date": "2025-12-17", "vote_average": 7.46,
                                                     "overview": "Pandora.", "poster_path": "/a.jpg"}]}).encode(), {}
            return 200, json.dumps({"results": []}).encode(), {}
        if "/search/tv" in url:
            return 200, json.dumps({"results": []}).encode(), {}
        if "/movie/" in url:
            return 200, json.dumps({"runtime": 190, "genres": [{"name": "Sci-Fi"}, {"name": "Adventure"}]}).encode(), {}
        return 404, b"", {}


class Scan(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        base = Path(self.td.name)
        self.lib, self.dd = base / "lib", base / "data"
        self.lib.mkdir()
        for n in REAL[:3] + [REAL[7]]:
            (self.lib / n).write_bytes(b"x" * 2000)
        self.s = {"library": str(self.lib), "min_size_mb": 0, "tmdb_key": "", "data_dir": str(self.dd), "network": True}
        self.orig = si.http_get
        self.net = FakeNet()
        si.http_get = self.net
        self.orig_which = si.shutil.which
        si.shutil.which = lambda n: None          # no ffmpeg: the raw download is kept

    def tearDown(self):
        si.http_get = self.orig
        si.shutil.which = self.orig_which
        self.td.cleanup()

    def cat(self):
        return json.loads((self.dd / "catalog.json").read_text())

    def test_scan_without_key_writes_catalog_and_does_no_network(self):
        self.assertEqual(si.cmd_scan(self.s), 0)
        c = self.cat()
        self.assertEqual(c["state"], "done")
        self.assertEqual(len(c["entries"]), 2)
        self.assertEqual(self.net.calls, [])
        self.assertFalse(os.path.exists(self.dd / "index.lock"))

    def test_scan_with_key_fills_metadata_and_poster(self):
        self.s["tmdb_key"] = "abc"
        self.assertEqual(si.cmd_scan(self.s), 0)
        c = self.cat()
        av = [e for e in c["entries"] if e["key"] == "avatar fire and ash"][0]
        self.assertEqual(av["meta"]["rating"], 7.5)
        self.assertEqual(av["meta"]["runtime"], 190)
        self.assertEqual(av["meta"]["genres"], ["Sci-Fi", "Adventure"])
        self.assertTrue(os.path.exists(self.dd / "posters" / av["meta"]["poster"]))
        self.assertTrue(any("api_key=abc" in u for u in self.net.calls))

    def test_second_scan_is_incremental(self):
        self.s["tmdb_key"] = "abc"
        si.cmd_scan(self.s)
        n = len(self.net.calls)
        si.cmd_scan(self.s)
        self.assertEqual(len(self.net.calls), n)

    def test_miss_is_remembered_then_retried_after_a_week(self):
        self.s["tmdb_key"] = "abc"
        si.cmd_scan(self.s)
        meta = json.load(open(self.dd / "meta.json"))["items"]
        miss = [k for k, v in meta.items() if v.get("miss")]
        self.assertEqual(len(miss), 1)            # the yearless IMAX film
        n = len(self.net.calls)
        si.cmd_scan(self.s)
        self.assertEqual(len(self.net.calls), n)
        for k in miss:
            meta[k]["fetched"] -= 8 * 86400
        json.dump({"v": 1, "items": meta}, open(self.dd / "meta.json", "w"))
        si.cmd_scan(self.s)
        self.assertGreater(len(self.net.calls), n)

    def test_bearer_token(self):
        seen = {}
        def net(url, headers=None, timeout=15):
            seen.update(headers or {})
            return 200, b'{"results": []}', {}
        si.http_get = net
        si.Tmdb("eyJabc.def.ghi").get_json("/search/movie", query="x")
        self.assertEqual(seen.get("Authorization"), "Bearer eyJabc.def.ghi")

    def test_bad_key_stops_quietly_and_keeps_catalog(self):
        self.s["tmdb_key"] = "bad"
        self.net.status = 401
        self.assertEqual(si.cmd_scan(self.s), 0)
        self.assertEqual(self.cat()["state"], "done")

    def test_rate_limit_retries(self):
        t = si.Tmdb("k", sleep=lambda s: None)
        answers = [(429, b"", {"Retry-After": "0"}), (200, b'{"a": 1}', {})]
        si.http_get = lambda *a, **k: answers.pop(0)
        self.assertEqual(t.get_json("/x"), {"a": 1})

    def test_offline_leaves_pending(self):
        self.s["tmdb_key"] = "abc"
        def down(*a, **k):
            raise si.Offline("no route")
        si.http_get = down
        self.assertEqual(si.cmd_scan(self.s), 0)
        c = self.cat()
        self.assertEqual(c["state"], "done")
        self.assertEqual(c["pending"], 2)
        self.assertTrue(all("meta" not in e for e in c["entries"]))

    def test_empty_library_leaves_old_catalog(self):
        si.cmd_scan(self.s)
        before = self.cat()
        for f in self.lib.iterdir():
            f.unlink()
        self.assertEqual(si.cmd_scan(self.s), 1)
        self.assertEqual(self.cat(), before)

    def test_stale_lock_is_taken_over_and_live_lock_respected(self):
        os.makedirs(self.dd)
        (self.dd / "index.lock").write_text("999999")
        self.assertEqual(si.cmd_scan(self.s), 0)
        self.assertEqual(self.cat()["state"], "done")
        (self.dd / "index.lock").write_text(str(os.getppid()))
        os.remove(self.dd / "catalog.json")
        self.assertEqual(si.cmd_scan(self.s), 0)
        self.assertFalse(os.path.exists(self.dd / "catalog.json"))      # skipped: another run is "active"

    def test_the_library_is_never_written(self):
        before = sorted((p.name, p.stat().st_mtime_ns, p.stat().st_size) for p in self.lib.rglob("*"))
        self.s["tmdb_key"] = "abc"
        si.cmd_scan(self.s)
        after = sorted((p.name, p.stat().st_mtime_ns, p.stat().st_size) for p in self.lib.rglob("*"))
        self.assertEqual(before, after)

    def test_settings_from_config(self):
        cfg = Path(self.td.name) / "c.ini"
        cfg.write_text("[seekthumbs]\nlibrary = /x\nmin_size_mb = 20000\n[shelf]\ntmdb_key = k1\nmin_size_mb = 5\n")
        class A: config = str(cfg); library = None; min_size_mb = None; tmdb_key = None; data_dir = None; no_network = False
        s = si.read_settings(A)
        self.assertEqual((s["library"], s["min_size_mb"], s["tmdb_key"]), ("/x", 5.0, "k1"))


class Cli(unittest.TestCase):
    def test_plan_pipe_head_is_quiet(self):
        import subprocess
        with tempfile.TemporaryDirectory() as td:
            for i in range(300):
                Path(td, f"Film{i}.2020.1080p.mkv").write_bytes(b"x")
            r = subprocess.run(f"{sys.executable} {ROOT / 'shelf-index'} --library {td} --config /nonexistent plan | head -2", shell=True, capture_output=True, text=True)
            self.assertEqual(r.stderr, "")
            self.assertEqual(len(r.stdout.splitlines()), 2)

    def test_no_library_message(self):
        import subprocess
        r = subprocess.run([sys.executable, str(ROOT / "shelf-index"), "--config", "/nonexistent", "plan"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("no library", r.stderr)


if __name__ == "__main__":
    unittest.main()
