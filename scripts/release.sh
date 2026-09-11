#!/usr/bin/env bash
# scripts/release.sh X.Y.Z [--preview] — cut a release locally, without pushing:
#   1. GREENLIGHT_VERSION in greenlight.sh becomes X.Y.Z
#   2. "## Unreleased" in CHANGELOG.md becomes "## vX.Y.Z — <today>"
#   3. one commit "Release vX.Y.Z" and an annotated tag vX.Y.Z
# Then YOU push: git push --follow-tags. The tag triggers .github/workflows/release.yml, which
# publishes the GitHub Release with the CHANGELOG section as notes. --preview only prints the
# notes that would ship (from the current Unreleased section) and changes nothing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$HERE"
ver="${1:-}"; mode="${2:-}"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 X.Y.Z [--preview]" >&2; exit 2; }
tag="v$ver"
cur="$(sed -n 's/^GREENLIGHT_VERSION="\(.*\)"$/\1/p' greenlight.sh)"
[[ -n "$cur" ]] || { echo "GREENLIGHT_VERSION not found in greenlight.sh" >&2; exit 1; }
grep -q '^## Unreleased$' CHANGELOG.md || { echo "CHANGELOG.md has no \"## Unreleased\" section — nothing to release" >&2; exit 1; }

if [[ "$mode" == "--preview" ]]; then
  echo "# would release $tag (current: $cur) with these notes:"; echo
  notes="$(awk '/^## /{ if (found) exit; found = ($2 == "Unreleased"); next } found { print }' CHANGELOG.md)"
  notes="${notes#"${notes%%[![:space:]]*}"}"; printf '%s\n' "${notes%"${notes##*[![:space:]]}"}"
  exit 0
fi

[[ "$ver" != "$cur" ]] || { echo "already at $cur" >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "release from main (on: $(git branch --show-current))" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "tag $tag already exists" >&2; exit 1; }
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main is not in sync with origin/main" >&2; exit 1; }

today="$(date +%F)"
perl -pi -e "s/^GREENLIGHT_VERSION=\"\Q$cur\E\"\$/GREENLIGHT_VERSION=\"$ver\"/" greenlight.sh
perl -pi -e "s/^## Unreleased\$/## $tag — $today/" CHANGELOG.md
[[ "$(sed -n 's/^GREENLIGHT_VERSION="\(.*\)"$/\1/p' greenlight.sh)" == "$ver" ]] || { echo "version bump failed" >&2; exit 1; }
scripts/release-notes.sh "$tag" >/dev/null   # the section must be extractable, or the workflow will fail later

git add greenlight.sh CHANGELOG.md
git commit -q -m "Release $tag"
git tag -a "$tag" -m "greenlight $tag"
echo "committed and tagged $tag (was $cur). Publish with:"
echo "  git push --follow-tags origin main"
