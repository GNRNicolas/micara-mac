#!/bin/bash
# Publishes a version of the Mac app: ./release.sh 0.2.0
#
# Run from the private monorepo (bridge-swift/ inside GNRNicolas/micara). It
# bumps VERSION in build.sh, commits, mirrors bridge-swift/ into the public
# repo GNRNicolas/micara-mac (git subtree split, history kept) and creates the
# GitHub release the app's daily update check reads. One command, no step to
# forget. Never part of build.sh: that one runs on users' machines.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version, e.g. 0.2.0>}"
PUBLIC_REPO="GNRNicolas/micara-mac"
PUBLIC_REMOTE="git@github-perso:$PUBLIC_REPO.git"
PREFIX="bridge-swift"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3"; exit 1; }
[ -z "$(git status --porcelain -- .)" ] || { echo "commit or stash your changes in $PREFIX/ first"; exit 1; }

# 1. Version bump, committed on the current branch.
sed -i '' "s/^VERSION=\"[0-9.]*\"$/VERSION=\"$VERSION\"/" build.sh
git add build.sh
git commit -q -m "release(mac): $VERSION"
echo "→ build.sh at $VERSION, committed"

# 2. Mirror: the history of bridge-swift/ alone, pushed as the public main.
ROOT="$(git rev-parse --show-toplevel)"
SPLIT="$(git -C "$ROOT" subtree split --prefix="$PREFIX" 2>/dev/null)"
git -C "$ROOT" push -q "$PUBLIC_REMOTE" "$SPLIT:main"
echo "→ mirrored into $PUBLIC_REPO"

# 3. The release the app looks for (tag_name vX.Y.Z, compared to VERSION).
gh auth switch -u GNRNicolas >/dev/null 2>&1 || true
gh release create "v$VERSION" --repo "$PUBLIC_REPO" --title "Micara $VERSION" \
  --notes "Update: in the folder you cloned, \`git pull && ./build.sh --install\` — or accept the prompt Micara shows within a day." >/dev/null
gh auth switch -u digimatsu >/dev/null 2>&1 || true
echo "→ https://github.com/$PUBLIC_REPO/releases/tag/v$VERSION"
echo "  Remember to push this branch of the private repo too."
