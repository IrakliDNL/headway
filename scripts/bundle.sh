#!/bin/zsh
# Wraps a Headway binary into Headway.app and signs it.  Usage: scripts/bundle.sh <binary> <app path> <identity|->
set -euo pipefail
cd "${0:A:h}/.."
BIN=$1 APP=$2 IDENTITY=$3
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Headway"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "$IDENTITY" --identifier com.irakli.headway "$APP"
codesign --verify "$APP"
