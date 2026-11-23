#!/bin/sh
# Ships a new JRG version: bumps the version, commits, tags, and pushes.
# GitHub Actions then builds it and publishes the update that JRG picks up.
# Usage: scripts/release.sh 1.2
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: scripts/release.sh <version, e.g. 1.2>}"
case "$VERSION" in v*) VERSION="${VERSION#v}";; esac

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or stash your changes first."; exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "v$VERSION already exists."; exit 1
fi

sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $VERSION;/" XRG.xcodeproj/project.pbxproj
git commit -qam "Release $VERSION" || true   # nothing to commit if the version was already set
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
echo "Pushed v$VERSION. Follow the build with: gh run watch"
