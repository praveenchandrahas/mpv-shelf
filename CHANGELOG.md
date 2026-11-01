# Changelog

## [0.1.0] - 2026-11-01

First packaged pre-release. Experimental. The code on main at the time of tagging is packaged as it is.

- Debian package `mpv-shelf` (Architecture: all): the `shelf-index` command in /usr/bin, and shelf.lua with its default options under /usr/share/mpv-shelf.
- `mpv-shelf-setup` copies the script into the user's mpv folders and adds the key (Ctrl+b) to input.conf in a marked block, with `--dry-run`, `uninstall` and a check for a hand-installed `shelf-index` in ~/.local/bin that would hide the packaged one. It reads the same marks as install-shelf.sh, so it can take over an existing hand install.
- The package scripts never write into a home folder and never touch audio configuration. Your catalog and watch history are never removed.
