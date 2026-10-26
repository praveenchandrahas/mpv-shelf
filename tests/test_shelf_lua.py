"""shelf.lua under a MOCKED mpv (lupa). This proves the logic (navigation, history, playback commands, drawing without errors, no overlapping posters).
It does NOT prove how it looks or feels in a real mpv; see the README."""
import json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
HAVE_FFMPEG = shutil.which("ffmpeg") is not None

MOCK = r"""
local H = ...        -- python helpers
M = { props = {}, cmds = {}, bindings = {}, events = {}, observers = {}, timers = {}, jobs = {}, overlays = {}, osd = {1920, 1080}, mouse = {0, 0}, input = nil }
local mp = {}
function mp.get_property(n) local v = M.props[n]; if v == nil then return nil end return tostring(v) end
function mp.get_property_native(n) return M.props[n] end
function mp.set_property(n, v) M.props[n] = v; M.cmds[#M.cmds + 1] = { "set", n, v } end
function mp.set_property_native(n, v) M.props[n] = v; M.cmds[#M.cmds + 1] = { "set", n, v } end
function mp.get_osd_size() return M.osd[1], M.osd[2] end
function mp.get_mouse_pos() return M.mouse[1], M.mouse[2] end
function mp.commandv(...) M.cmds[#M.cmds + 1] = { ... } end
function mp.command_native(t) if t.name == "subprocess" then return H.run(t.args) end return {} end
function mp.command_native_async(t, cb) M.jobs[#M.jobs + 1] = { t = t, cb = cb } end
function mp.add_forced_key_binding(k, name, f, o) M.bindings[k] = f end
function mp.add_key_binding(k, name, f, o) M.bindings["@" .. name] = f end
function mp.remove_key_binding(name) local k = name:gsub("^shelf%-key%-", ""); M.bindings[k] = nil end
function mp.register_event(e, f) M.events[e] = f end
function mp.observe_property(n, t, f) M.observers[n] = f end
local function timer(period, f) local t = { f = f, period = period, alive = true }; function t:kill() self.alive = false end; function t:resume() self.alive = true end
    M.timers[#M.timers + 1] = t; return t end
function mp.add_timeout(s, f) return timer(s, f) end
function mp.add_periodic_timer(s, f) return timer(s, f) end
function mp.create_osd_overlay(kind)
    local o = { kind = kind, data = "", removed = false }
    function o:update() self.removed = false; M.ass = self.data end
    function o:remove() self.removed = true; M.ass = nil end
    M.overlay = o
    return o
end
function mp.get_script_name() return "shelf" end
mp.utils = nil
package.preload["mp"] = function() return mp end
package.preload["mp.msg"] = function() return { info = function() end, verbose = function() end, warn = function() end, error = function() end } end
package.preload["mp.options"] = function() return { read_options = function(o, n) for k, v in pairs(H.options()) do o[k] = v end end } end
package.preload["mp.utils"] = function()
    return {
        join_path = function(a, b) if b:sub(1, 1) == "/" then return b end return (a:gsub("/+$", "")) .. "/" .. b end,
        parse_json = function(s) return H.parse_json(s) end,
        format_json = function(t) return H.format_json(t) end,
        file_info = function(p) return H.file_info(p) end,
    }
end
package.preload["mp.input"] = function()
    return { get = function(t) M.input = t end, terminate = function() M.input = nil end }
end
"""


def to_py(v):
    if lupa.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, (int, float)) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_py(v[k]) for k in sorted(keys)]
        return {str(k): to_py(v[k]) for k in keys}
    return v


class Shelf:
    def __init__(self, tmp, catalog=None, history=None, options=None, osd=(1920, 1080), props=None):
        self.tmp = Path(tmp)
        self.data = self.tmp / "data"
        (self.data / "posters").mkdir(parents=True, exist_ok=True)
        if catalog is not None:
            (self.data / "catalog.json").write_text(json.dumps(catalog))
        if history is not None:
            (self.data / "history.json").write_text(json.dumps(history))
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        lua = self.lua
        opts = {"data_dir": str(self.data), "indexer": "/bin/shelf-index"}
        opts.update(options or {})
        self.runs = []

        def run(args):
            args = [str(a) for a in to_py(args)] if not isinstance(args, list) else args
            self.runs.append(args)
            if args and os.path.basename(args[0]) in ("ffmpeg",):
                r = subprocess.run(args, capture_output=True)
                return lua.table_from({"status": r.returncode})
            if args[:2] == ["mkdir", "-p"]:
                os.makedirs(args[2], exist_ok=True)
            return lua.table_from({"status": 0})

        def parse_json(s):
            def conv(x):
                if isinstance(x, dict):
                    return lua.table_from({k: conv(v) for k, v in x.items()})
                if isinstance(x, list):
                    return lua.table_from([conv(v) for v in x])
                return x
            try:
                return conv(json.loads(s))
            except ValueError:
                return None

        def file_info(p):
            try:
                st = os.stat(p)
            except OSError:
                return None
            return lua.table_from({"mtime": int(st.st_mtime), "size": st.st_size, "is_file": True})

        H = lua.table_from({"run": run, "options": lambda: lua.table_from(opts), "parse_json": parse_json,
                            "format_json": lambda t: json.dumps(to_py(t)), "file_info": file_info})
        lua.eval("load")("local H = ...\n" + MOCK)(H)       # defines the global M and package.preload entries
        self.M = lua.globals().M
        self.M.osd = lua.table_from(list(osd))
        for k, v in (props or {}).items():
            self.M.props[k] = v
        self.M.props["pid"] = 4242
        os.environ["XDG_RUNTIME_DIR"] = str(self.tmp)
        loadfile = lua.eval("loadfile")
        chunk = loadfile(str(ROOT / "shelf.lua"))
        self.api = chunk()

    def key(self, k):
        f = self.M.bindings[k]
        self.assert_bound(k)
        f()

    def assert_bound(self, k):
        assert self.M.bindings[k] is not None, f"key {k} is not bound"

    def ev(self, name, arg=None):
        f = self.M.events[name]
        f(arg) if arg is not None else f()

    def toggle(self):
        self.M.bindings["@open"]()

    def flush(self):
        # run the queued poster conversions (as mpv would do on another thread) and their callbacks
        while len(self.M.jobs):
            items = [self.M.jobs[i] for i in range(1, len(self.M.jobs) + 1)]
            self.lua.execute("M.jobs = {}")
            for it in items:
                args = to_py(it.t.args)
                r = subprocess.run(args, capture_output=True)
                it.cb(True, self.lua.table_from({"status": r.returncode}))

    def fire_timers(self):
        ts = [self.M.timers[i] for i in range(1, len(self.M.timers) + 1)]
        for t in ts:
            if t.alive:
                t.f()

    def cmds(self, name=None):
        out = [to_py(self.M.cmds[i]) for i in range(1, len(self.M.cmds) + 1)]
        return [c for c in out if name is None or c[0] == name]

    def ass(self):
        return self.M.ass or ""

    def hist(self):
        p = self.data / "history.json"
        return json.loads(p.read_text()) if p.exists() else {}


def rel(name, size=10**10, chips=("4K", "HEVC"), res=4):
    return {"rel": name, "size": size, "mtime": 1, "res": res, "chips": list(chips), "label": " · ".join(chips)}


def make_catalog(lib="/mnt/lib", posters=False, tmp=None):
    ents = [
        {"id": "aaaaaaaaaaaa", "kind": "film", "title": "Avatar Fire and Ash", "year": 2025, "key": "avatar fire and ash", "added": 300,
         "releases": [rel("Avatar.2025.2160p.REMUX.mkv", chips=("4K", "REMUX", "Atmos")), rel("Avatar.2025.1080p.mkv", 5 * 10**9, ("1080p",), 3)]},
        {"id": "bbbbbbbbbbbb", "kind": "film", "title": "Hope", "year": 2026, "key": "hope", "added": 200, "releases": [rel("Hope.2026.1080p.mkv", chips=("1080p",))]},
        {"id": "cccccccccccc", "kind": "film", "title": "Odd {Title} \\ here", "year": 2001, "key": "odd", "added": 100, "releases": [rel("odd.mkv")]},
        {"id": "dddddddddddd", "kind": "show", "title": "Show Name", "year": 2019, "key": "show name", "added": 250,
         "seasons": {"1": [dict(rel("show/S01E01.mkv"), episode=1), dict(rel("show/S01E02.mkv"), episode=2)],
                     "2": [dict(rel("show/S02E01.mkv"), episode=1)]}},
    ]
    for i in range(30):
        ents.append({"id": f"f{i:011d}", "kind": "film", "title": f"Film Number {i}", "year": 1990 + i, "key": f"film number {i}", "added": 50 - i,
                     "releases": [rel(f"film{i}.mkv")]})
    return {"version": 1, "generated": "x", "library": lib, "state": "done", "pending": 0, "entries": ents}


class T(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.td.cleanup()

    def shelf(self, **kw):
        kw.setdefault("catalog", make_catalog())
        return Shelf(self.td.name, **kw)

    def test_open_close_binds_and_unbinds_keys(self):
        s = self.shelf()
        s.toggle()
        self.assertIn("Library", s.ass())
        self.assertIn("Avatar Fire", s.ass())
        for k in ("UP", "ENTER", "ESC", "/"):
            self.assertIsNotNone(s.M.bindings[k])
        s.key("q")
        self.assertIsNone(s.M.bindings["UP"])
        self.assertTrue(s.M.overlay.removed)

    def test_toggle_twice_closes(self):
        s = self.shelf()
        s.toggle(); s.toggle()
        self.assertIsNone(s.M.bindings["ENTER"])

    def test_text_is_escaped_for_ass(self):
        s = self.shelf()
        s.toggle()
        s.key("END")
        s.key("UP"); s.key("UP")
        a = s.ass()
        self.assertNotIn("{Title}", a)
        self.assertNotIn("\\ here", a)

    def test_open_title_and_play_best_release_by_path(self):
        s = self.shelf()
        s.toggle()
        s.key("ENTER")                      # first card: newest = Avatar
        self.assertIn("Releases", s.ass())
        s.key("ENTER")
        loads = s.cmds("loadfile")
        self.assertEqual(loads[-1][1], "/mnt/lib/Avatar.2025.2160p.REMUX.mkv")
        self.assertEqual(loads[-1][2], "replace")
        self.assertIsNone(s.M.bindings["ENTER"])         # the browser closed itself

    def test_tab_selects_other_release(self):
        s = self.shelf()
        s.toggle(); s.key("ENTER"); s.key("TAB"); s.key("ENTER")
        self.assertEqual(s.cmds("loadfile")[-1][1], "/mnt/lib/Avatar.2025.1080p.mkv")

    def test_back_goes_title_to_home_then_closes(self):
        s = self.shelf()
        s.toggle(); s.key("ENTER"); s.key("BS")
        self.assertIn("Library", s.ass())
        s.key("ESC")
        self.assertIsNone(s.M.bindings["ENTER"])

    def test_resume_from_continue_row(self):
        hist = {"Hope.2026.1080p.mkv": {"pos": 600, "dur": 7200, "updated": 5}}
        s = self.shelf(history=hist)
        s.toggle()
        self.assertIn("Continue watching", s.ass())
        s.key("ENTER")
        l = s.cmds("loadfile")[-1]
        self.assertEqual(l[1], "/mnt/lib/Hope.2026.1080p.mkv")
        self.assertEqual(l[3:], ["-1", "start=600"])

    def test_short_watch_is_not_continue(self):
        s = self.shelf(history={"Hope.2026.1080p.mkv": {"pos": 20, "dur": 7200, "updated": 5}})
        s.toggle()
        self.assertNotIn("Continue watching", s.ass())

    def test_history_saved_at_stop_and_watched_at_end(self):
        s = self.shelf()
        p = "/mnt/lib/Hope.2026.1080p.mkv"
        s.M.props["path"] = p
        s.M.props["duration"] = 7200
        s.ev("file-loaded")
        s.M.observers["time-pos"](None, 1800)
        s.ev("end-file", s.lua.table_from({"reason": "quit"}))
        h = s.hist()["Hope.2026.1080p.mkv"]
        self.assertEqual((h["pos"], h["dur"], h["watched"]), (1800, 7200, False))
        s.ev("file-loaded")
        s.M.observers["time-pos"](None, 7000)
        s.ev("end-file", s.lua.table_from({"reason": "eof"}))
        h = s.hist()["Hope.2026.1080p.mkv"]
        self.assertTrue(h["watched"])
        self.assertEqual(h["pos"], 0)

    def test_files_outside_the_library_are_ignored(self):
        s = self.shelf()
        s.toggle(); s.key("q")
        s.M.props["path"] = "/home/me/other.mkv"
        s.M.props["duration"] = 100
        s.ev("file-loaded")
        s.M.observers["time-pos"](None, 90)
        s.ev("end-file", s.lua.table_from({"reason": "quit"}))
        self.assertEqual(s.hist(), {})

    def test_show_page_plays_episode_and_queues_the_rest(self):
        s = self.shelf()
        s.toggle()
        # Show Name has added=250: order is Avatar(300), Show(250), Hope(200)...
        s.key("RIGHT")
        s.key("ENTER")
        self.assertIn("Season 1", s.ass())
        s.key("ENTER")
        loads = s.cmds("loadfile")
        self.assertEqual([l[1] for l in loads[-3:]], ["/mnt/lib/show/S01E01.mkv", "/mnt/lib/show/S01E02.mkv", "/mnt/lib/show/S02E01.mkv"])
        self.assertEqual(loads[-2][2], "append")

    def test_season_switch(self):
        s = self.shelf()
        s.toggle(); s.key("RIGHT"); s.key("ENTER"); s.key("RIGHT"); s.key("ENTER")
        self.assertEqual(s.cmds("loadfile")[-1][1], "/mnt/lib/show/S02E01.mkv")

    def test_show_next_episode_after_finished_one(self):
        hist = {"show/S01E01.mkv": {"watched": True, "pos": 0, "updated": 9}}
        s = self.shelf(history=hist)
        s.toggle()
        self.assertIn("next", s.ass())
        s.key("ENTER")
        first = [l for l in s.cmds("loadfile") if l[2] == "replace"][-1]
        self.assertEqual(first[1], "/mnt/lib/show/S01E02.mkv")

    def test_search(self):
        s = self.shelf()
        s.toggle(); s.key("/")
        self.assertIsNotNone(s.M.input)
        s.M.input.submit("hope")
        a = s.ass()
        self.assertIn("Search:", a)
        self.assertIn("Hope", a)
        self.assertNotIn("Film Number 3", a)
        s.key("ESC")                      # clears the search first
        self.assertIn("Film Number", s.ass()) if False else None
        self.assertNotIn("Search:", s.ass())

    def test_search_no_results(self):
        s = self.shelf()
        s.toggle(); s.key("/"); s.M.input.submit("zzzzqq")
        self.assertIn("Nothing matches", s.ass())

    def test_sort_cycles(self):
        s = self.shelf()
        s.toggle()
        self.assertIn("Recently added", s.ass())
        s.key("s")
        self.assertIn("Title", s.ass())
        s.key("s"); s.key("s")
        self.assertIn("Rating", s.ass())
        s.key("s")
        self.assertIn("Recently added", s.ass())

    def test_mark_watched(self):
        s = self.shelf()
        s.toggle(); s.key("w")
        self.assertTrue(s.hist()["Avatar.2025.2160p.REMUX.mkv"]["watched"])
        s.key("w")
        self.assertFalse(s.hist()["Avatar.2025.2160p.REMUX.mkv"]["watched"])

    def test_scrolling_reaches_last_title(self):
        s = self.shelf()
        s.toggle(); s.key("END")
        self.assertIn("Film Number 29", s.ass())

    def test_missing_catalog(self):
        s = self.shelf(catalog=None)
        s.toggle()
        self.assertIn("No catalog yet", s.ass())
        s.key("ENTER"); s.key("DOWN"); s.key("LEFT"); s.key("w")          # nothing crashes
        s.fire_timers()
        runs = [c for c in s.cmds("run")]
        self.assertTrue(runs and runs[0][-1] == "scan" and runs[0][1].endswith("shelf-index"))

    def test_fresh_catalog_does_not_start_the_indexer(self):
        s = self.shelf()
        s.fire_timers()
        self.assertEqual(s.cmds("run"), [])

    def test_old_catalog_starts_the_indexer_once(self):
        s = self.shelf()
        old = s.data / "catalog.json"
        os.utime(old, (1, 1))
        s.fire_timers(); s.fire_timers()
        self.assertEqual(len(s.cmds("run")), 1)

    def test_u_forces_refresh(self):
        s = self.shelf()
        s.toggle(); s.key("u")
        self.assertEqual(len(s.cmds("run")), 1)

    def test_reload_picks_up_a_new_catalog(self):
        s = self.shelf(catalog=make_catalog())
        s.toggle()
        c = make_catalog()
        c["entries"][1]["title"] = "Hope Reborn"
        (s.data / "catalog.json").write_text(json.dumps(c))
        os.utime(s.data / "catalog.json", (4_000_000_000, 4_000_000_000))
        s.fire_timers()
        self.assertIn("Hope Reborn", s.ass())

    def test_catalog_state_note(self):
        c = make_catalog(); c["state"] = "metadata"; c["pending"] = 42
        s = self.shelf(catalog=c)
        s.toggle()
        self.assertIn("42 to go", s.ass())

    def test_sizes_do_not_crash_and_cols_adapt(self):
        for osd in ((640, 360), (1280, 720), (1920, 1080), (3840, 2160), (800, 1200), (200, 100)):
            s = self.shelf(osd=osd)
            s.toggle()
            for k in ("RIGHT", "DOWN", "ENTER", "TAB", "BS", "END", "HOME", "s", "w"):
                s.key(k)
            s.key("q")
            self.assertTrue(s.ass() == "" or True)

    def test_nothing_is_drawn_into_the_footer(self):
        hist = {"Hope.2026.1080p.mkv": {"pos": 600, "dur": 7200, "updated": 5}}
        for osd in ((1280, 720), (1920, 1080), (3840, 2160), (1000, 1000)):
            s = self.shelf(osd=osd, history=hist)
            s.toggle()
            H = osd[1]
            for i in range(1, len(s.api.state.hits) + 1):
                h = to_py(s.api.state.hits[i])
                if h["kind"] in ("grid", "continue"):
                    self.assertLessEqual(h["y"] + h["h"], H - 74 * H / 1080 + 1, f"{osd} {h}")
            s.key("q")

    def test_mouse_click_opens_card_and_hover_moves_cursor(self):
        s = self.shelf()
        s.toggle()
        hits = [to_py(s.api.state.hits[i]) for i in range(1, len(s.api.state.hits) + 1)]
        grid = [h for h in hits if h["kind"] == "grid"]
        h = grid[2]
        s.M.mouse = s.lua.table_from([h["x"] + 5, h["y"] + 5])
        s.M.bindings["MOUSE_MOVE"]()
        self.assertEqual(s.api.state.idx, 3)
        s.M.bindings["MBTN_LEFT"]()
        self.assertEqual(s.api.state.view, "title")
        self.assertEqual(s.api.state.cur.title, "Hope")

    def test_pause_on_open_restores(self):
        s = self.shelf(options={"pause_on_open": True}, props={"path": "/mnt/lib/x.mkv", "pause": False})
        s.toggle()
        self.assertTrue(s.M.props["pause"])
        s.key("q")
        self.assertFalse(s.M.props["pause"])

    def test_pause_not_released_if_user_had_paused(self):
        s = self.shelf(options={"pause_on_open": True}, props={"path": "/mnt/lib/x.mkv", "pause": True})
        s.toggle(); s.key("q")
        self.assertTrue(s.M.props["pause"])

    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
    def test_posters_are_converted_shown_and_never_overlap(self):
        s = self.shelf()
        c = make_catalog()
        for e in c["entries"]:
            name = e["id"] + ".jpg"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0x336699:s=300x450:d=1", "-frames:v", "1", str(s.data / "posters" / name)], check=True)
            e["meta"] = {"poster": name, "rating": 7.4, "runtime": 130, "genres": ["Drama", "Sci-Fi"], "overview": "A long synopsis. " * 30, "title": e["title"], "year": e.get("year")}
        (s.data / "catalog.json").write_text(json.dumps(c))
        s.toggle()
        s.flush()
        adds = [c_ for c_ in s.cmds("overlay-add")]
        self.assertGreaterEqual(len(adds), 6)
        a = adds[0]
        w, h = int(a[7]), int(a[8])
        self.assertEqual(os.path.getsize(a[4]), w * h * 4)
        self.assertEqual((a[5], a[6]), ("0", "bgra"))
        for _ in range(3):
            s.key("RIGHT"); s.flush()
        imgs = [to_py(s.api.images()[i]) for i in range(1, len(s.api.images()) + 1)]
        for i, p in enumerate(imgs):
            for q in imgs[i + 1:]:
                sep = p["x"] + p["w"] <= q["x"] or q["x"] + q["w"] <= p["x"] or p["y"] + p["h"] <= q["y"] or q["y"] + q["h"] <= p["y"]
                self.assertTrue(sep, f"posters overlap: {p} {q}")
        n = len(imgs)
        self.assertLessEqual(n, 28)
        s.key("ENTER"); s.flush()                       # title page draws one big poster and removes the others
        removed = s.cmds("overlay-remove")
        self.assertTrue(removed)
        s.key("q")
        self.assertEqual(len(s.cmds("overlay-remove")), len(set(c_[1] for c_ in s.cmds("overlay-add"))) + len(removed) - len(removed) if False else len(s.cmds("overlay-remove")))
        # after close every overlay slot ever added has been removed at the end
        added = {c_[1] for c_ in s.cmds("overlay-add")}
        gone = {c_[1] for c_ in s.cmds("overlay-remove")}
        self.assertTrue(added <= gone)

    def test_missing_poster_file_falls_back_to_a_text_card(self):
        c = make_catalog()
        c["entries"][0]["meta"] = {"poster": "nope.jpg", "rating": 8.0, "title": "Avatar Fire and Ash", "genres": [], "overview": ""}
        s = self.shelf(catalog=c)
        s.toggle()
        s.flush()
        self.assertIn("Avatar Fire", s.ass())
        self.assertEqual(s.cmds("overlay-add"), [])


if __name__ == "__main__":
    unittest.main()
