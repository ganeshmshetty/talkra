#!/bin/bash
# Proves a change touched comments only: for every modified .swift file, the lines that are not
# full-line comments must be identical to the base revision.
# Usage: ./scripts/verify_comment_only.sh [base-ref]   (default: HEAD)
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
base="${1:-HEAD}"
strip() { grep -vE '^[[:space:]]*//' ; }
bad=0
for f in $(git diff --name-only "$base" -- 'Sources/*.swift' 'Tests/*.swift'); do
    if ! diff -qb <(git show "$base:$f" | strip) <(strip < "$f") >/dev/null; then
        echo "CODE CHANGED: $f"; bad=1
    fi
done
[ $bad -eq 0 ] && echo "verify: only comment lines differ" || exit 1
