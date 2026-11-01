#!/usr/bin/env bash
# Runs every test. Needs python3, lupa (pip install lupa) and ffmpeg for the poster tests (they skip without ffmpeg).
set -eo pipefail   # without pipefail the tail at the end hid a failing test run
cd "$(dirname "$0")/.."
python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_*.py' -v 2>&1 | tail -n "${TAIL:-8}"
