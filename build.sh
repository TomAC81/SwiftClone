#!/bin/bash
# Builds SwiftClone.app with the Swift toolchain alone (no Xcode needed).
#   ./build.sh            release build -> prints the path of the .app
#   ./build.sh --install  also copies it to ~/Applications
#   ./build.sh --run      also launches it
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product SwiftClone
BIN="$(swift build -c release --show-bin-path)/SwiftClone"

# The bundle is assembled and signed outside the project folder: folders
# synced by iCloud/File Provider attach extended attributes that codesign rejects.
OUT="${SWIFTCLONE_BUILD_DIR:-$HOME/Library/Caches/SwiftClone-build}"
APP="$OUT/SwiftClone.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SwiftClone"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
# Ad-hoc signature: enough to run locally. Distribution needs a Developer ID.
codesign --force --sign - "$APP"
echo "Built $APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/SwiftClone.app"
      ditto "$APP" "$HOME/Applications/SwiftClone.app"
      echo "Installed to $HOME/Applications/SwiftClone.app" ;;
    --run) open "$APP" ;;
  esac
done
