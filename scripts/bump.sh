#!/bin/sh
# Sets the version to x.y.z, adds one to the build number, and commits it. Usage: scripts/bump.sh 1.2.0
set -eu
cd "$(dirname "$0")/.."

version="${1#v}"
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "usage: scripts/bump.sh x.y.z" >&2; exit 1; }

project=peekaboo/peekaboo.xcodeproj/project.xcproj
build=$(sed -nE 's/.*"CURRENT_PROJECT_VERSION": "([0-9]+)".*/\1/p' "$project" | head -1)
sed -i '' -E \
    -e "s/(\"CURRENT_PROJECT_VERSION\": \")[0-9]+/\1$((build + 1))/" \
    -e "s/(\"MARKETING_VERSION\": \")[^\"]+/\1$version/" \
    "$project"
git commit -m "chore: bump version to $version" -- "$project"
echo "$version ($((build + 1)))"
