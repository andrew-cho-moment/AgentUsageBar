#!/bin/bash
set -euo pipefail

APP_NAME="AgentUsageBar"
OUTPUT_DIR="release"

if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <major.minor.patch>" >&2
    exit 2
fi

VERSION="$1"
cd "$(dirname "$0")"

CODESIGN_IDENTITY=- ./build.sh "$VERSION"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/disk"
cp -R "build/$APP_NAME.app" "$OUTPUT_DIR/disk/"
ln -s /Applications "$OUTPUT_DIR/disk/Applications"

DMG="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$OUTPUT_DIR/disk" \
    -ov \
    -format UDZO \
    "$DMG"
rm -rf "$OUTPUT_DIR/disk"

(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS)
echo "Packaged $DMG"
