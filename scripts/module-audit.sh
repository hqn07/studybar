#!/usr/bin/env bash
# Render every module of the window — three widths, dark and light — plus each module on an
# empty store and the menu-bar popover, into <out-dir> with an index.html to look through.
#
#   scripts/module-audit.sh <out-dir>
#
# Run it before a release: two layout bugs reached the user first because nothing looked at
# every screen at every width. It renders from a test copy (scripts/test-copy.sh): rendering the
# window writes preferences, and the Debug build otherwise shares the installed app's.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: scripts/module-audit.sh <out-dir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

set +e
./scripts/test-copy.sh --module-audit "$OUT"
status=$?
set -e

echo "$(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') PNGs in $OUT"
exit $status
