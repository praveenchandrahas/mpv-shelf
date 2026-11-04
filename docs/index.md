# mpv-shelf

A Netflix-style film browser for [mpv](https://mpv.io), over a **local folder** such as a debrid/WebDAV mount. Posters, ratings and quality chips, a Continue Watching row, search, TV seasons, and it remembers where you stopped.

It is part of the [Software Defined Home Theatre](https://github.com/praveenchandrahas/Software-Defined-Home-Theatre) project. The main repository holds the documentation, build log, results and the installer checks; mpv-shelf is one of its parts.

## What it is, and what it is not

* It **reads** your library folder (directory listing and `stat` only, never file contents) and **never writes** to it. Everything it creates lives in `~/.local/share/mpv-shelf`.
* It plays by the **real file path**, so other things that key on the path keep working: [seekthumbs](https://github.com/praveenchandrahas/seekthumbs) thumbnails, a launcher wrapper such as `mpv-atmos`, profile detection.
* One card per film: releases of the same title and year are **one card** with a release picker (best first: resolution, REMUX, size). A name with no year is never merged with anything.
* It is not a media server: no transcoding, no remote access, no multi-user.

## Status

This is a pre-release, experimental project — see the [repository README](https://github.com/praveenchandrahas/mpv-shelf) for the current test status in detail. Real mpv behaviour (poster bitmaps, keyboard capture, search) is still being verified against the author's own rig.

## Next

* [Install](install.md) — getting the package in, the TMDB key, and building the catalog.
* [Usage](usage.md) — opening the shelf, keys, options, and what to do if something looks wrong.
