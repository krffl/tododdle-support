#!/bin/sh
# Writes the version in /VERSION into the Swift SDK's SDKVersion.swift.
# Run it after you change /VERSION and before you tag a release.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
version=$(tr -d '[:space:]' < "$root/VERSION")
target="$root/swift/Sources/TododdleSupport/SDKVersion.swift"
tmp="$target.tmp"
sed -E "s/(public static let sdkVersion = \")[^\"]*(\")/\1$version\2/" "$target" > "$tmp"
mv "$tmp" "$target"
echo "SDKVersion.swift now says $version"
