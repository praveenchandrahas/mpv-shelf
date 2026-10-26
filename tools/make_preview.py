#!/usr/bin/env python3
"""Draws docs/img/preview-*.png: the REAL ASS output of shelf.lua (from the test harness) rendered with libass over a dummy frame, with
illustrative placeholder posters pasted where the script asks for bitmaps. It is a SIMULATION: mpv itself is not involved."""
import json, subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tests"))
from PIL import Image, ImageDraw, ImageFont
import test_shelf_lua as T

OUT = Path(__file__).resolve().parent.parent / "docs" / "img"
TITLES = [("Avatar Fire and Ash", 2025, 7.5, 190, ["Sci-Fi", "Adventure"]), ("Hope", 2026, 6.9, 108, ["Drama"]), ("Project Hail Mary", 2026, 8.1, 156, ["Sci-Fi"]),
          ("The Imitation Game", 2014, 8.0, 114, ["Drama", "War"]), ("It Ends", 2025, 6.0, 98, ["Horror"]), ("Sampoorna Ramayanam", 1972, 7.2, 180, ["Drama"]),
          ("IMAX Wolves", 2001, 6.4, 40, ["Documentary"]), ("Film Number Eight", 2019, 7.0, 121, ["Comedy"]), ("Film Number Nine", 2018, 6.6, 99, ["Action"]),
          ("Film Number Ten", 2017, 7.7, 133, ["Thriller"]), ("Film Number Eleven", 2016, 5.9, 92, ["Drama"]), ("Film Number Twelve", 2015, 7.3, 125, ["Mystery"]),
          ("Film Number Thirteen", 2014, 6.8, 104, ["Drama"]), ("Film Number Fourteen", 2013, 7.9, 140, ["War"]), ("Film Number Fifteen", 2012, 6.1, 96, ["Comedy"]),
          ("Film Number Sixteen", 2011, 7.4, 118, ["Drama"])]
PAL = [(0x2b, 0x4c, 0x7e), (0x6b, 0x2d, 0x5c), (0x1f, 0x6f, 0x5c), (0x8a, 0x4b, 0x2a), (0x3d, 0x3d, 0x8f), (0x7a, 0x2e, 0x2e)]


def poster_file(path, i, title):
    w, h = 300, 450
    im = Image.new("RGB", (w, h))
    c = PAL[i % len(PAL)]
    d = ImageDraw.Draw(im)
    for y in range(h):
        k = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(a * (1 - 0.6 * k)) for a in c))
    f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 30)
    words, line, y = title.split(), "", 150
    for wd in words:
        t = (line + " " + wd).strip()
        if d.textlength(t, font=f) > w - 40:
            d.text((w / 2, y), line, font=f, fill=(255, 255, 255), anchor="mm"); y += 38; line = wd
        else:
            line = t
    d.text((w / 2, y), line, font=f, fill=(255, 255, 255), anchor="mm")
    im.save(path, quality=90)


def background(size):
    w, h = size
    im = Image.new("RGB", (w, h), (10, 12, 16))
    d = ImageDraw.Draw(im)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=(18 + int(14 * y / h), 22 + int(10 * y / h), 34 + int(24 * y / h)))
    return im


def render(name, steps, osd=(1920, 1080), history=None, simulated="SIMULATED PREVIEW: libass rendering of shelf.lua's output with placeholder posters. Not a screenshot of mpv."):
    with tempfile.TemporaryDirectory() as td:
        cat = T.make_catalog()
        cat["entries"] = cat["entries"][:0] + [
            {"id": f"id{i:010d}", "kind": "film", "title": t[0], "year": t[1], "key": t[0].lower(), "added": 1000 - i,
             "meta": {"poster": f"id{i:010d}.jpg", "rating": t[2], "runtime": t[3], "genres": t[4], "title": t[0], "year": t[1],
                      "overview": "A placeholder synopsis for the simulated preview. The real text comes from TMDB when you have set a key. " * 2},
             "releases": [T.rel(f"{t[0]}.mkv", 62 * 10**9, ("4K", "REMUX", "HDR10+", "Atmos", "TrueHD", "HEVC"), 4), T.rel(f"{t[0]}.1080p.mkv", 9 * 10**9, ("1080p", "WEB-DL", "DD+"), 3)]}
            for i, t in enumerate(TITLES)]
        sh = T.Shelf(td, catalog=cat, history=history or {}, osd=osd)
        for i, t in enumerate(TITLES):
            poster_file(sh.data / "posters" / f"id{i:010d}.jpg", i, t[0])
        sh.toggle(); sh.flush()
        for k in steps:
            sh.key(k); sh.flush()
        ass = sh.ass()
        imgs = [T.to_py(sh.api.images()[i]) for i in range(1, len(sh.api.images()) + 1)]
        W, H = osd
        assf = Path(td) / "o.ass"
        assf.write_text("[Script Info]\nScriptType: v4.00+\nPlayResX: %d\nPlayResY: %d\nWrapStyle: 2\n\n[V4+ Styles]\n"
                        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
                        "Style: Default,Inter,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n\n[Events]\n"
                        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" % (W, H)
                        + "".join("Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,%s\n" % ln for ln in ass.split("\n")))
        bg = Path(td) / "bg.png"; background((W, H)).save(bg)
        out = Path(td) / "ass.png"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(bg), "-vf", f"ass={assf}", "-frames:v", "1", str(out)], check=True)
        im = Image.open(out).convert("RGB")
        for p in imgs:
            ph = Image.open(p["file"] if False else p["file"].replace(".bgra", ".bgra"))  if False else None
            raw = Path(p["file"]).read_bytes()
            a = Image.frombuffer("RGBA", (p["w"], p["h"]), raw, "raw", "BGRA", 0, 1)
            im.paste(a.convert("RGB"), (int(p["x"]), int(p["y"])))
        d = ImageDraw.Draw(im)
        f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18)
        d.rectangle([0, H - 30, W, H], fill=(60, 20, 20))
        d.text((12, H - 15), simulated, font=f, fill=(255, 220, 200), anchor="lm")
        im.save(OUT / name)
        print("wrote", OUT / name)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    hist = {f"{TITLES[2][0]}.mkv": {"pos": 3100, "dur": 9360, "updated": 9}, f"{TITLES[4][0]}.mkv": {"pos": 800, "dur": 5900, "updated": 8}}
    render("preview-home.png", ["RIGHT"], history=hist)
    render("preview-title.png", ["DOWN", "ENTER"], history=hist)
