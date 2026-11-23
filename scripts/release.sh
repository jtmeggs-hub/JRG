#!/bin/sh
# Ships a new JRG version from this Mac: bumps the version, builds it, signs the
# update with the key in your Keychain, and publishes a GitHub release with
# JRG.zip and appcast.xml. Installed copies of JRG pick it up within a day
# (or right away with Check now).
#
# Usage: scripts/release.sh 1.2
#
# (Building here instead of on GitHub's Mac runners avoids their long queues.)
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: scripts/release.sh <version, e.g. 1.2>}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
REPO="$(gh repo view "$(git remote get-url origin)" --json nameWithOwner -q .nameWithOwner)"
DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUILD_DIR="$HOME/Developer/JRG-build"
BIN="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
OUT="$BUILD_DIR/release-$VERSION"

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or stash your changes first."; exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "$TAG is already released."; exit 1
fi

# Tag (or reuse a tag that already points here but never got a release).
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || { echo "$TAG exists on a different commit."; exit 1; }
else
  sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $VERSION;/" XRG.xcodeproj/project.pbxproj
  git commit -qam "Release $VERSION" || true
  git tag "$TAG"
fi
BUILD="$(git rev-list --count HEAD)"

echo "Building JRG $VERSION ($BUILD)…"
DEVELOPER_DIR="$DEV" xcodebuild -project XRG.xcodeproj -scheme XRG -configuration Release \
  -derivedDataPath "$BUILD_DIR" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  build -quiet
APP="$BUILD_DIR/Build/Products/Release/JRG.app"

rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/JRG.zip"
SIGNATURE="$("$BIN/sign_update" --account JRG "$OUT/JRG.zip")"
scripts/make-appcast.sh "$VERSION" "$BUILD" \
  "https://github.com/$REPO/releases/download/$TAG/JRG.zip" "$SIGNATURE" > "$OUT/appcast.xml"

git push -q origin HEAD "$TAG"
gh release create "$TAG" "$OUT/JRG.zip" "$OUT/appcast.xml" --repo "$REPO" \
  --title "JRG $VERSION" --generate-notes
echo "Released JRG $VERSION ($BUILD)."
