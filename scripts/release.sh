#!/bin/bash
# 배포용 빌드: Developer ID 서명 → 공증 → 스테이플 → zip
#
# 처음 한 번 공증 계정을 키체인에 저장해 둔다:
#   xcrun notarytool store-credentials trackbanner --apple-id <이메일> --team-id <TEAMID>
#
# 사용법: scripts/release.sh
#   결과: build/TrackBanner-<버전>.zip 과 그 SHA-256
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:=Developer ID Application: JUNHYEOK HONG (6PWGJVPT55)}"
: "${NOTARY_PROFILE:=trackbanner}"
export SIGN_IDENTITY

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP=build/TrackBanner.app
ZIP=build/TrackBanner-$VERSION.zip

./build.sh
codesign --verify --strict --verbose=2 "$APP"

# 공증 제출용 zip (ditto 로 묶어야 번들 메타데이터가 보존된다)
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# 공증 티켓을 앱에 붙인 뒤 배포용 zip 을 다시 만든다
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Version: $VERSION"
echo "Archive: $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
