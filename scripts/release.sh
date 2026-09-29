#!/bin/zsh
# Builds the downloadable app: a universal (Apple silicon + Intel) Headway.app, ad-hoc signed, zipped.
# Not notarized (that needs the paid Apple Developer Program), so people allow it once via
# System Settings › Privacy & Security › Open Anyway.
#   scripts/release.sh   → build/Headway-<version>.zip
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -vE "^\[|^Building|^Compiling|^Write" || true
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Headway"
lipo -info "$BIN"

scripts/bundle.sh "$BIN" build/release/Headway.app -
ZIP="build/Headway-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/release/Headway.app "$ZIP"
shasum -a 256 "$ZIP"
echo "Built $ZIP"
