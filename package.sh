#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
APP_NAME="MacExplorer"
DISPLAY_NAME="Mac Explorer"
BUILD_DIR="${MAC_EXPLORER_BUILD_DIR:-$HOME/Library/Caches/MacExplorerBuild}"
RELEASE_DIR="release"
APP="$BUILD_DIR/$DISPLAY_NAME.app"

./build.sh release

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$DISPLAY_NAME.app"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE/$DISPLAY_NAME.app" \
    "$RELEASE_DIR/Mac-Explorer-$VERSION.zip"

ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO \
    "$RELEASE_DIR/Mac-Explorer-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
trap - EXIT
# Keep only distributable archives in release/ so Spotlight never sees a second app copy.
touch "$RELEASE_DIR/.metadata_never_index"

echo "Packaged:"
ls -lh "$RELEASE_DIR"
