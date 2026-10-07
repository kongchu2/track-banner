#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Apple Silicon + Intel 유니버설 바이너리
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_PATH=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

APP=build/SpotifyAlert.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/SpotifyAlert" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

echo "Built $APP"
