# Install

## Pre-release package (experimental)

Releases are marked **pre-release** on the [releases page](https://github.com/praveenchandrahas/mpv-shelf/releases). Download the `.deb` and `SHA256SUMS` from one release, check, then install:

```sh
sha256sum -c --ignore-missing SHA256SUMS
sudo apt install ./mpv-shelf_0.1.0_all.deb
mpv-shelf-setup --dry-run   # then: mpv-shelf-setup install
```

Needs mpv with Lua and ffmpeg.

The package puts files under `/usr` only. Its install and remove scripts do not enable or start services, do not write into any home folder, and do not touch CamillaDSP or PipeWire configuration; the `mpv-shelf-setup` command above does the per-user part, and `--dry-run` shows what it would do first. Details, the other repositories' packages, and the one-command installer are in the main repository's [packaging notes](https://github.com/praveenchandrahas/Software-Defined-Home-Theatre/blob/main/docs/packaging.md).

What was checked: written with an AI assistant; checked against simulated rooms and REW exports; used and checked by the author in his own room (one room, one author). No external or second-person validation yet. The packages are unsigned. CI installs and removes them in clean Ubuntu 24.04; the packaging itself has not been run on the author's own rig.

Needs mpv 0.38 or newer (search uses `mp.input`; resume uses `loadfile ... -1 start=N`), `python3`, and `ffmpeg` for posters.

## Setup, step by step

```bash
# 1. get it
cd ~/sdht-workspace/mpv-shelf             # wherever this folder lives

# 2. see what it would show, no writes, no network
python3 shelf-index plan | head -40
python3 shelf-index plan | tail -1

# 3. install (only touches ~/.local/bin and your mpv config; safe to run again)
./install-shelf.sh

# 4. optional but recommended: posters and ratings (see "TMDB key" below)
nano ~/.config/seekthumbs/config.ini        # add the [shelf] block shown below

# 5. build the catalog (first run is the slow one; Ctrl+C is safe, it resumes)
shelf-index scan
shelf-index status

# 6. open any film with mpv, then press Ctrl+b
mpv /mnt/decypharr/__all__/some-film.mkv
```

`library` is read from `~/.config/seekthumbs/config.ini`, so if seekthumbs already works for you there is nothing to repeat. To use a different folder or file, put a `[shelf]` section there:

```ini
[shelf]
library = /mnt/decypharr/__all__
min_size_mb = 0            ; 0 = every video file
tmdb_key = PASTE_KEY_HERE
network = yes
```

Lookup order for each setting: `[shelf]`, then `[seekthumbs]`, then the default. So with no `[shelf] min_size_mb`, the seekthumbs value (for example 20000 MB) applies and small files are hidden. Set `min_size_mb = 0` under `[shelf]` to see everything.

Skipped on purpose: anything that is not a video file (`.iso`, `.rar`, `.nfo`, subtitles and so on).

## TMDB key (free)

1. Make an account at themoviedb.org, then open Settings, API.
2. Request a key for personal use. You get an **API Key** (32 hex characters) and a **Read Access Token** (starts with `eyJ`). Either works; paste one as `tmdb_key`.
3. Without a key, everything works: cards show titles and quality chips, no posters, ratings or synopsis.

This product uses the TMDB API but is not endorsed or certified by TMDB. Posters are cached once in `~/.local/share/mpv-shelf/posters`; requests are throttled (about 4 a second) and retried on rate limits. A film TMDB does not know is retried after a week.

## Relation to seekthumbs

Separate repo, separate job: seekthumbs makes the seek-bar thumbnails, mpv-shelf is the browser. They share the library setting and nothing else. Because mpv-shelf plays the real path, thumbnails appear for films you start from the shelf exactly as when you start them from the command line.

## Development

```bash
pip install lupa            # and have ffmpeg installed
tests/run.sh                # 68 tests
python3 tools/make_preview.py   # redraws docs/img/preview-*.png
```
