#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Apple Silicon + Intel 유니버설 바이너리
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_PATH=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

APP=build/TrackBanner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/TrackBanner" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Built $APP"
