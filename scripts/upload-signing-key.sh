#!/bin/sh
# One-time setup: copies the Sparkle update-signing key from your Keychain into the
# repository's SPARKLE_PRIVATE_KEY secret, so GitHub Actions can sign releases.
# The exported key lives only in a private temp folder that's deleted right after.
set -eu
cd "$(dirname "$0")/.."
BIN="$HOME/Developer/JRG-build/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$BIN/generate_keys" ] || { echo "Build JRG once first so Sparkle's tools are downloaded."; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$BIN/generate_keys" --account JRG -x "$TMP/key"
gh secret set SPARKLE_PRIVATE_KEY < "$TMP/key"
echo "SPARKLE_PRIVATE_KEY is set."
