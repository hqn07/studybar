#!/usr/bin/env bash
# Count corner radii written as raw numbers instead of DS.Radius tokens, and fail if there are
# more than last time. A ratchet: the old ones are cleaned up as rows are touched, and no new
# one gets in — twelve different radii crept in with three tokens defined.
#
#   scripts/design-lint.sh            # check
#   scripts/design-lint.sh --update   # lower the ceiling to the current count
set -euo pipefail
cd "$(dirname "$0")/.."

count=$(grep -rnE '(cornerRadius|RoundedRectangle\(cornerRadius): *[0-9]' Sources --include='*.swift' \
  | grep -v 'Shell/DesignSystem.swift' | wc -l | tr -d ' ')
baseline=$(cat scripts/design-lint.baseline)

if [ "${1:-}" = "--update" ]; then
  echo "$count" > scripts/design-lint.baseline
  echo "Raw corner radii: $count (ceiling set to $count)"
  exit 0
fi

echo "Raw corner radii: $count (ceiling $baseline)"
if [ "$count" -gt "$baseline" ]; then
  echo "New raw corner radius — use DS.Radius.control / .card / .modal:"
  grep -rnE '(cornerRadius|RoundedRectangle\(cornerRadius): *[0-9]' Sources --include='*.swift' | grep -v 'Shell/DesignSystem.swift' | tail -5
  exit 1
fi
