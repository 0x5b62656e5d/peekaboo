#!/bin/sh
# Builds a Release app and zips it to build/peekaboo.zip.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodebuild -project peekaboo/peekaboo.xcodeproj -scheme peekaboo -configuration Release -derivedDataPath build/dd build -quiet
ditto -c -k --keepParent build/dd/Build/Products/Release/peekaboo.app build/peekaboo.zip
echo "build/peekaboo.zip"
