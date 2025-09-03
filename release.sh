#!/bin/bash
# Packs both apps and publishes them as a GitHub release.
set -e
cd "$(dirname "$0")"
VERSION="${1:?укажи версию, например ./release.sh v1.0}"

./setup.sh
mkdir -p release
rm -f release/*

ditto -c -k --keepParent mac/TabScreen.app "release/TabScreen-mac.zip"
cp android/build/tabscreen.apk "release/tabscreen-android.apk"

gh release create "$VERSION" release/* \
  --title "TabScreen $VERSION" \
  --notes-file .github/release-notes.md

echo "выложено: $VERSION"
