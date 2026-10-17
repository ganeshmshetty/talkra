#!/bin/bash
# Fails on comment patterns the policy in AGENTS.md ("Comments") bans.
# Usage: ./scripts/lint_comments.sh [paths...]   (default: Sources Tests)
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

PATTERN='//.*(\(was [0-9]|\bwas [0-9.]+ ?(s|ms|pt)\b|[Pp]reviously|[Pp]revious [0-9]|[Ii]nternal for tests?\.?$|[Ll]ifecycle mirrors|[Bb]enchmark \()'

paths=("$@"); [ ${#paths[@]} -eq 0 ] && paths=(Sources Tests)
hits=$(git ls-files "${paths[@]/%//*.swift}" | xargs grep -nE "$PATTERN" 2>/dev/null)
if [ -n "$hits" ]; then
    echo "$hits"
    echo
    echo "comment lint: $(echo "$hits" | wc -l | tr -d ' ') banned comment(s). See AGENTS.md > Comments."
    exit 1
fi
echo "comment lint: clean"
