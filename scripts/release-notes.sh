#!/usr/bin/env bash
# scripts/release-notes.sh vX.Y.Z — prints the CHANGELOG.md section of that version (the body
# under "## vX.Y.Z — <date>", up to the next "## "). Exit 1 if the section does not exist, so a
# tag whose CHANGELOG entry is still "## Unreleased" cannot be released. Used by
# .github/workflows/release.yml and by scripts/release.sh --preview.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 vX.Y.Z" >&2; exit 2; }
notes="$(awk -v tag="$tag" '
  /^## / { if (found) exit; found = ($2 == tag); next }
  found { print }
' "$HERE/CHANGELOG.md")"
[[ -n "${notes//[[:space:]]/}" ]] || { echo "CHANGELOG.md has no \"## $tag — <date>\" section (still \"## Unreleased\"?)" >&2; exit 1; }
notes="${notes#"${notes%%[![:space:]]*}"}"; notes="${notes%"${notes##*[![:space:]]}"}"   # trim blank lines at both ends
printf '%s\n' "$notes"
