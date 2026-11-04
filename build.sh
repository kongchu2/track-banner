#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# 서명 인증서. 비우면 애드혹 서명(내 맥에서만 실행용).
# 예: SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" ./build.sh
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

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

# Developer ID 서명에는 공증에 필요한 강화된 런타임 + 보안 타임스탬프를 붙인다.
SIGN_OPTS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_OPTS+=(--options runtime --timestamp --entitlements TrackBanner.entitlements)
fi
codesign "${SIGN_OPTS[@]}" "$APP"

echo "Built $APP"
