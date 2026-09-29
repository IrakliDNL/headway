#!/bin/zsh
# Builds Headway.app for this Mac, signs it, installs it to ~/Applications and restarts it.
#   scripts/build.sh            build + install + relaunch
#   scripts/build.sh --no-run   build + install only
#
# Signing: uses $HEADWAY_SIGN_IDENTITY if set, else your first "Apple Development" certificate
# (Xcode › Settings › Accounts gives you one free), else ad-hoc. With a certificate, macOS remembers the
# Camera and Accessibility permissions across rebuilds; ad-hoc builds have to be re-allowed after each rebuild.
set -euo pipefail
cd "${0:A:h}/.."

IDENTITY="${HEADWAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
[[ -n "$IDENTITY" ]] || IDENTITY="-"
APP=build/Headway.app
DEST="$HOME/Applications/Headway.app"

if ! swift build -c release > .build/last-build.log 2>&1; then
  grep -E "error|warning: unre" .build/last-build.log | head -20
  echo "build failed — nothing installed"; exit 1
fi
BIN="$(swift build -c release --show-bin-path)/Headway"

scripts/bundle.sh "$BIN" "$APP" "$IDENTITY"

pkill -x Headway 2>/dev/null && sleep 0.5 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R $APP "$DEST"
echo "Installed $DEST (signed: ${IDENTITY/#-/ad-hoc})"

if [[ "${1:-}" != "--no-run" ]]; then
  open "$DEST"
  echo "Launched."
fi
