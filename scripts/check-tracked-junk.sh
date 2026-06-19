#!/usr/bin/env bash
# Tracked-junk gate — fail if any ignored-class artifact is tracked in git.
#
# This gates .gitignore drift itself: junk like caches, .omc/, tfstate,
# *.tsbuildinfo and empty/orphan dirs can never silently creep back into version
# control. This is a real merge-blocking gate (exit 1 on a tracked artifact);
# CI runs it without continue-on-error, so red means "junk got committed".
#
# Part of the HESO P0 hygiene baseline (full spec lives in the redesign plan).
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2

# Ignored-class path patterns that must never be tracked, anchored to path
# segments so a legitimately-named file can't false-positive.
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
