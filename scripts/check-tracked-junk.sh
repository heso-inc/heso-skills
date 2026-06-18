#!/usr/bin/env bash
# Tracked-junk gate — fail if any ignored-class artifact is tracked in git.
#
# This gates .gitignore drift itself: the junk the kill-list removed (caches,
# .omc/, tfstate, *.tsbuildinfo, empty/orphan dirs) can never silently creep
# back into version control. Report-only in P0 (CI runs it under
# continue-on-error to capture the baseline); flips merge-blocking in P7.
#
# See redesign/refactor/hygiene-and-ci.md §6.4 and redesign/kill-list.md.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2

# Ignored-class path patterns that must never be tracked, anchored to path
# segments so a legitimately-named file can't false-positive. NOTE: *.wasm is
# intentionally NOT listed — untracking heso_wasm_bg.wasm is deferred to the P3
# SDK split (the publish pipeline consumes the tracked artifact today).
patterns='(^|/)(__pycache__|\.ruff_cache|\.pytest_cache|\.mypy_cache|\.venv|node_modules|\.next|\.turbo|target|\.terraform|\.omc|\.conductor|\.cursor)/|\.(pyc|pyo|tsbuildinfo|tfstate)($|\.)|(^|/)\.DS_Store$'

hits=$(git ls-files | grep -E "$patterns" || true)

# Tracked env files: anything matching .env or .env.* except .env.example.
env_hits=$(git ls-files | grep -E '(^|/)\.env($|\.)' | grep -vE '(^|/)\.env\.example$' || true)

all=$(printf '%s\n%s\n' "$hits" "$env_hits" | sed '/^$/d')

if [ -n "$all" ]; then
  echo "✗ tracked-junk gate: ignored-class artifacts are tracked:" >&2
  printf '%s\n' "$all" | sed 's/^/    /' >&2
  echo "  → git rm --cached <path> and confirm .gitignore covers it." >&2
  exit 1
fi
echo "✓ tracked-junk gate: no ignored-class artifacts tracked."
