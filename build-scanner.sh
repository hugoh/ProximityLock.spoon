#!/bin/sh
# Builds ProximityLockScanner.app from the spoon's sources into <cache>/<hash>.
# Usage: build-scanner.sh <source dir> <cache dir> <hash>
set -eu

source_dir=$1
cache=$2
hash=$3
staging="$cache/$hash.tmp"
final="$cache/$hash"
app="$staging/ProximityLockScanner.app"

rm -rf "$staging"
mkdir -p "$app/Contents/MacOS"
/usr/bin/swiftc -O "$source_dir/scan.swift" -o "$app/Contents/MacOS/ProximityLockScanner"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
mv "$staging" "$final"

# Apps built from older sources are no longer needed.
for old in "$cache"/*; do
	[ "$old" = "$final" ] || rm -rf "$old"
done
