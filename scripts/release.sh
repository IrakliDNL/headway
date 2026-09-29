#!/bin/zsh
# Builds the downloadable app: a universal (Apple silicon + Intel) Headway.app, ad-hoc signed, zipped.
# Not notarized (that needs the paid Apple Developer Program), so people allow it once via
# System Settings › Privacy & Security › Open Anyway.
#   scripts/release.sh   → build/Headway-<version>.zip
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

if ! swift build -c release --arch arm64 --arch x86_64 > .build/last-release.log 2>&1; then
  grep -E "error" .build/last-release.log | head -20
  echo "build failed"; exit 1
fi
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Headway"
lipo -info "$BIN"

scripts/bundle.sh "$BIN" build/release/Headway.app -
ZIP="build/Headway-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/release/Headway.app "$ZIP"
shasum -a 256 "$ZIP"
echo "Built $ZIP"
