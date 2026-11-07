#!/bin/sh
# Builds a Release app and zips it to build/peekaboo.zip.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Building the target rather than a scheme skips Xcode's run-destination lookup, which only logs noise here.
xcodebuild -project peekaboo/peekaboo.xcodeproj -target peekaboo -configuration Release \
    SYMROOT="$PWD/build/products" OBJROOT="$PWD/build/intermediates" build -quiet
ditto -c -k --keepParent build/products/Release/peekaboo.app build/peekaboo.zip
echo "build/peekaboo.zip"
