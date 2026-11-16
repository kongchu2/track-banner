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

# Spotify 자체 가사를 받아 오는 사이드카(Rust, lyrics-sidecar/). cargo가 없으면 빼고 만들고, 그 앱은 가사를 LRCLIB에서만 찾는다.
# 배포용은 REQUIRE_SIDECAR=1 로 빠지지 않게 한다.
SIDECAR=""
if ! command -v cargo >/dev/null && [ -x "$HOME/.cargo/bin/cargo" ]; then
    PATH="$HOME/.cargo/bin:$PATH"
fi
if command -v cargo >/dev/null; then
    # 툴체인과 두 타깃은 lyrics-sidecar/rust-toolchain.toml 에 적혀 있어 rustup이 알아서 받는다.
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
        (cd lyrics-sidecar && cargo build --release --locked --target "$target")
    done
    SIDECAR=build/lyrics-sidecar
    mkdir -p build
    lipo -create -output "$SIDECAR" \
        lyrics-sidecar/target/aarch64-apple-darwin/release/lyrics-sidecar \
        lyrics-sidecar/target/x86_64-apple-darwin/release/lyrics-sidecar
elif [ "${REQUIRE_SIDECAR:-0}" = 1 ]; then
    echo "error: cargo가 없어 lyrics-sidecar를 빌드할 수 없습니다 (https://rustup.rs)." >&2
    exit 1
else
    echo "warning: cargo가 없어 lyrics-sidecar 없이 만듭니다 (Spotify 가사 로그인 불가, LRCLIB만 사용)." >&2
fi

APP=build/TrackBanner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/TrackBanner" "$APP/Contents/MacOS/"
if [ -n "$SIDECAR" ]; then mv "$SIDECAR" "$APP/Contents/MacOS/lyrics-sidecar"; fi
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Developer ID 서명에는 공증에 필요한 강화된 런타임 + 보안 타임스탬프를 붙인다.
SIGN_OPTS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_OPTS+=(--options runtime --timestamp)
fi
# 번들 안의 실행 파일을 먼저 서명해야 번들 서명이 그것을 봉인한다. 사이드카에는 Apple Events 권한이 필요 없다.
if [ -n "$SIDECAR" ]; then
    codesign "${SIGN_OPTS[@]}" --identifier com.kongchu2.trackbanner.lyrics-sidecar "$APP/Contents/MacOS/lyrics-sidecar"
fi
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_OPTS+=(--entitlements TrackBanner.entitlements)
fi
codesign "${SIGN_OPTS[@]}" "$APP"

echo "Built $APP"
