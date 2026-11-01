#!/usr/bin/env bash
# Smoke test of the INSTALLED mpv-shelf package. Throw-away HOME; a tiny fake library; no network (TMDB is never contacted: no key, network off).
#   scripts/ci-smoke.sh
set -euo pipefail
H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
export HOME=$H XDG_CONFIG_HOME=$H/.config XDG_DATA_HOME=$H/.local/share SDHT_ALLOW_ROOT=1   # the clean-environment test runs as root, with a throw-away HOME
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
for c in shelf-index mpv-shelf-setup; do command -v "$c" >/dev/null || fail "$c is not on PATH"; done
[ "$(command -v shelf-index)" = /usr/bin/shelf-index ] || fail "shelf-index resolves to $(command -v shelf-index)"
[ -f /usr/share/mpv-shelf/shelf.lua ] || fail "shelf.lua missing"

echo "== catalog from a fake library (names only; nothing is opened)"
LIB=$H/films; mkdir -p "$LIB/Arrival.2016.1080p.BluRay" "$LIB/Heat.1995.2160p.Remux"
head -c 2000000 /dev/zero > "$LIB/Arrival.2016.1080p.BluRay/Arrival.2016.1080p.BluRay.mkv"
head -c 3000000 /dev/zero > "$LIB/Heat.1995.2160p.Remux/Heat.1995.2160p.Remux.mkv"
mkdir -p "$H/.config/seekthumbs"
printf '[shelf]\nlibrary=%s\nmin_size_mb=0\nnetwork=no\ndata_dir=%s/data\n' "$LIB" "$H" > "$H/.config/seekthumbs/config.ini"
shelf-index plan | tee "$H/plan.txt"
grep -q Arrival "$H/plan.txt" && grep -q Heat "$H/plan.txt" || fail "plan lacks the films"
[ ! -e "$H/data" ] || fail "plan wrote files"
shelf-index scan >"$H/scan.txt" 2>&1 || { tail -20 "$H/scan.txt"; fail "scan"; }
[ -f "$H/data/catalog.json" ] || { tail -20 "$H/scan.txt"; fail "no catalog.json"; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("catalog keys:", sorted(d)[:6])' "$H/data/catalog.json"
shelf-index status | head -5

echo "== setup command"
mpv-shelf-setup --dry-run install | tee "$H/dry.txt"
[ ! -e "$H/.config/mpv" ] || fail "dry run created ~/.config/mpv"
mpv-shelf-setup install >/dev/null
[ -f "$H/.config/mpv/scripts/shelf.lua" ] || fail "shelf.lua not installed"
grep -q 'script-binding shelf/open' "$H/.config/mpv/input.conf" || fail "key not added"
mpv-shelf-setup install >/dev/null                       # idempotent: still one block
[ "$(grep -c '>>> mpv-shelf' "$H/.config/mpv/input.conf")" = 1 ] || fail "block duplicated"
mpv-shelf-setup uninstall >/dev/null
[ ! -e "$H/.config/mpv/scripts/shelf.lua" ] || fail "uninstall left shelf.lua"
! grep -q 'mpv-shelf' "$H/.config/mpv/input.conf" || fail "uninstall left the block"
[ -f "$H/data/catalog.json" ] || fail "uninstall removed the catalog"
echo "SMOKE OK (mpv-shelf)"
