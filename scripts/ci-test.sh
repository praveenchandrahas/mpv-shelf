#!/usr/bin/env bash
# The repository's full test suite, the same command in CI and on your machine. Needs python3, python3-lupa; ffmpeg for the poster tests.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TAIL=${TAIL:-200} bash tests/run.sh
