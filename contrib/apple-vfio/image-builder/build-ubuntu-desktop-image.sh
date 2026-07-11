#!/usr/bin/env bash
#
# Back-compat wrapper: the build pipeline moved to build-image.sh and
# grew profiles. This preserves the original entry point + argv
# (`build-ubuntu-desktop-image.sh [output-dir]`).
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/build-image.sh" desktop "$@"
