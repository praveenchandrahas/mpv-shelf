#!/usr/bin/env bash
# Installs mpv-shelf for the current user. Nothing outside your home folder is touched.
#   ./install-shelf.sh            install (or update; safe to run again)
#   ./install-shelf.sh remove     take it out again (your catalog and history are kept)
#   ./install-shelf.sh --help
# Environment: HOME, XDG_CONFIG_HOME, SHELF_BIN (default ~/.local/bin), SHELF_KEY (default Ctrl+b)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN="${SHELF_BIN:-$HOME/.local/bin}"
KEY="${SHELF_KEY:-Ctrl+b}"
BINDING="$KEY script-binding shelf/open"
BEGIN="# >>> mpv-shelf (managed by install-shelf.sh)"
END="# <<< mpv-shelf"
DIRS=("$CFG/mpv" "$CFG/mpv-object-audio")

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

strip_block() {   # remove our block and any stray bare-number lines (a shell variable once leaked a number into input.conf)
    local f="$1"
    [ -f "$f" ] || return 0
    local tmp; tmp="$(mktemp)"
    awk -v b="$BEGIN" -v e="$END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip { next }
        /^[0-9]+$/ { next }
        { print }' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}

case "${1:-install}" in
    -h|--help) usage; exit 0 ;;
    remove)
        for d in "${DIRS[@]}"; do
            rm -f "$d/scripts/shelf.lua" "$d/script-opts/shelf.conf.default"
            strip_block "$d/input.conf"
        done
        rm -f "$BIN/shelf-index"
        echo "Removed. Your catalog and watch history stay in ~/.local/share/mpv-shelf (delete that folder yourself if you want them gone)."
        exit 0 ;;
    install) ;;
    *) usage; exit 2 ;;
esac

for f in shelf.lua shelf-index script-opts/shelf.conf; do
    [ -f "$HERE/$f" ] || { echo "Missing $HERE/$f. Run this from a full checkout." >&2; exit 1; }
done
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }
command -v ffmpeg  >/dev/null || echo "Note: ffmpeg is not on PATH; posters need it." >&2

mkdir -p "$BIN"
install -m 755 "$HERE/shelf-index" "$BIN/shelf-index"
echo "Installed $BIN/shelf-index"

for d in "${DIRS[@]}"; do
    # ~/.config/mpv always; the Atmos config folder only if it exists already
    if [ "$d" != "$CFG/mpv" ] && [ ! -d "$d" ]; then continue; fi
    mkdir -p "$d/scripts" "$d/script-opts"
    install -m 644 "$HERE/shelf.lua" "$d/scripts/shelf.lua"
    # the options file is yours once it exists: never overwritten, the shipped defaults go next to it
    if [ ! -f "$d/script-opts/shelf.conf" ]; then install -m 644 "$HERE/script-opts/shelf.conf" "$d/script-opts/shelf.conf"; fi
    install -m 644 "$HERE/script-opts/shelf.conf" "$d/script-opts/shelf.conf.default"
    touch "$d/input.conf"
    strip_block "$d/input.conf"
    if grep -Eq '^[[:space:]]*'"${KEY//+/\\+}"'[[:space:]]' "$d/input.conf"; then
        echo "Note: $d/input.conf already binds $KEY elsewhere; add this yourself if you want it: $BINDING" >&2
    else
        { printf '%s\n%s\n%s\n' "$BEGIN" "$BINDING" "$END"; } >> "$d/input.conf"
    fi
    echo "Installed into $d ($KEY opens the shelf)"
done
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: $BIN is not on your PATH; add it, or set indexer=$BIN/shelf-index in shelf.conf." >&2 ;; esac
echo "Next: shelf-index plan, then shelf-index scan (see the README)."
