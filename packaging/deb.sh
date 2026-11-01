# shellcheck shell=bash disable=SC2034  # sourced by build-deb.sh, which uses these variables
# Package definition for kit/build-deb.sh (sourced; see Software-Defined-Home-Theatre/packaging/kit).
PKG=mpv-shelf
HOMEPAGE=https://github.com/praveenchandrahas/mpv-shelf
SUMMARY="film browser for mpv: posters, ratings and a Continue Watching row"
DESCRIPTION="A film browser that runs inside mpv (shelf.lua) on top of a catalog that
the shelf-index command builds from a film library. The library is only listed,
never opened or written. Posters and ratings come from TMDB when you add a key;
without one the catalog still works with titles and quality chips.
.
This package does not write into any home folder; run mpv-shelf-setup to put
the script and its key into your mpv folders."
DEPENDS="python3"
RECOMMENDS="ffmpeg, mpv"
SUGGESTS="seekthumbs"
PYDIRS=

stage() {
  inst 755 shelf-index /usr/bin/shelf-index; pyshebang /usr/bin/shelf-index
  inst 644 shelf.lua /usr/share/mpv-shelf/shelf.lua
  inst 644 script-opts/shelf.conf /usr/share/mpv-shelf/shelf.conf
  inst 755 packaging/mpv-shelf-setup /usr/bin/mpv-shelf-setup
  manpage shelf-index "build the catalog that the mpv-shelf browser shows (scan, plan, status)"
  manpage mpv-shelf-setup "install the mpv-shelf script and its key into the mpv folders of one user" "Subcommands: install, uninstall, check. Option: --dry-run. Environment: SHELF_KEY (default Ctrl+b), XDG_CONFIG_HOME."
}
