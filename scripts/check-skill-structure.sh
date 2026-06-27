#!/usr/bin/env bash
# Skill structure/lint gate — the markdown-repo analogue of the per-language LINT
# gate (hygiene-and-ci.md §1: STYLE/LINT must exist for every repo's content).
#
# heso-skills ships no code, so there is no clippy/ruff/eslint here. What CAN rot
# in a skill repo is structure: a SKILL.md missing required frontmatter, a
# reference link pointing at a file that does not exist (a dead link a user would
# hit mid-task), or an orphan reference file no SKILL.md links to (dead content).
# This gate catches all three. It is a REAL merge-blocking gate (exit 1 on any
# violation); CI runs it without continue-on-error.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2

fail=0
note() { echo "✗ $*" >&2; fail=1; }

shopt -s nullglob
skills=(skills/*/SKILL.md)
if [ ${#skills[@]} -eq 0 ]; then
  note "no skills/*/SKILL.md found — a skill repo must ship at least one skill."
  exit 1
fi

for skill in "${skills[@]}"; do
  dir=$(dirname "$skill")

  # 1. Frontmatter: a leading `---` block carrying `name:` and `description:`.
  first=$(head -1 "$skill")
  if [ "$first" != "---" ]; then
    note "$skill: missing leading \`---\` YAML frontmatter."
    continue
  fi
  front=$(awk 'NR>1 && /^---[[:space:]]*$/{exit} NR>1{print}' "$skill")
  printf '%s\n' "$front" | grep -qE '^name:' || note "$skill: frontmatter missing \`name:\`."
  printf '%s\n' "$front" | grep -qE '^description:' || note "$skill: frontmatter missing \`description:\`."

  # 2. Every relative .md link in SKILL.md must resolve to a real file.
  links=$(grep -oE '\]\(([^)]+\.md)\)' "$skill" | sed -E 's/^\]\(//; s/\)$//' || true)
  for link in $links; do
    case "$link" in
      http*|/*) continue ;;  # external / absolute — out of scope
    esac
    target="$dir/${link%%#*}"
    [ -f "$target" ] || note "$skill: dead link → '$link' (no file at $target)."
  done

  # 3. Every reference file must be linked from this skill (no orphan content).
  if [ -d "$dir/references" ]; then
    for ref in "$dir"/references/*.md; do
      base="references/$(basename "$ref")"
      grep -qF "$base" "$skill" || note "$ref: orphan reference — not linked from $skill."
    done
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "  → fix the structure violations above; the skill repo must stay navigable." >&2
  exit 1
fi
echo "✓ skill structure gate: frontmatter present, links resolve, no orphan references."
