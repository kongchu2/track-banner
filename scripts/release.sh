#!/bin/bash
# 배포: Developer ID 서명 → 공증 → 스테이플 → zip → GitHub 릴리스 → Homebrew 탭 갱신
#
# 처음 한 번 공증 계정을 키체인에 저장해 둔다:
#   xcrun notarytool store-credentials trackbanner --apple-id <이메일> --team-id <TEAMID>
#
# 사용법:
#   1. Info.plist 의 CFBundleShortVersionString / CFBundleVersion 을 올리고 커밋·푸시
#   2. scripts/release.sh            (빌드와 공증만 하려면 scripts/release.sh --no-publish)
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

PUBLISH=1
for arg in "$@"; do
    case "$arg" in
        --no-publish) PUBLISH=0 ;;
        *) die "알 수 없는 옵션: $arg (사용법: scripts/release.sh [--no-publish])" ;;
    esac
done

TEAM_ID=6PWGJVPT55
: "${NOTARY_PROFILE:=trackbanner}"
# 환경에 애드혹 값(-)이 남아 있어도 배포에는 쓰지 않는다.
if [ -z "${SIGN_IDENTITY:-}" ] || [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_IDENTITY="Developer ID Application: JUNHYEOK HONG ($TEAM_ID)"
fi
export SIGN_IDENTITY

REPO=kongchu2/track-banner
TAP_REPO=kongchu2/homebrew-tap
CASK=Casks/track-banner.rb

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
APP=build/TrackBanner.app
ZIP=build/TrackBanner-$VERSION.zip
SUBMIT_ZIP=build/TrackBanner-$VERSION-notarize.zip

TAP_DIR=""
KEEP_TAP_DIR=0
cleanup() {
    rm -f "$SUBMIT_ZIP"
    if [ -n "$TAP_DIR" ] && [ "$KEEP_TAP_DIR" = 0 ]; then rm -rf "$TAP_DIR"; fi
}
trap cleanup EXIT

# ---- 사전 점검: 오래 걸리는 빌드·공증 전에 실패할 일은 모두 여기서 걸러낸다 ----

# 배포 파일이 커밋된 소스와 같도록, 깨끗한 작업 트리에서만 만든다.
git diff --quiet HEAD -- || die "커밋 안 된 변경이 있습니다. 커밋한 뒤 다시 실행하세요."
[ -z "$(git ls-files --others --exclude-standard)" ] || die "추적 안 된 파일이 있습니다. 커밋하거나 지운 뒤 다시 실행하세요."
# 빌드한 커밋. 공증을 기다리는 사이 HEAD 가 바뀌어도 태그는 이 커밋에 붙는다.
HEAD_SHA=$(git rev-parse HEAD)

if [ "$PUBLISH" = 1 ]; then
    gh auth status >/dev/null 2>&1 || die "gh 에 로그인되어 있지 않습니다 (gh auth login)."
    git fetch -q origin main
    [ "$HEAD_SHA" = "$(git rev-parse origin/main)" ] || die "HEAD 가 origin/main 과 다릅니다. 푸시한 뒤 다시 실행하세요."

    # 태그나 릴리스(초안 포함)가 이미 있으면 멈춘다. gh 자체 오류는 '없음'으로 보지 않는다.
    TAG_CHECK=0
    git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || TAG_CHECK=$?
    [ "$TAG_CHECK" = 2 ] || { [ "$TAG_CHECK" = 0 ] && die "$TAG 태그가 이미 있습니다. Info.plist 버전을 올리세요."; die "원격 태그를 확인하지 못했습니다."; }
    if RELEASE_ERR=$(gh release view "$TAG" --repo "$REPO" 2>&1 >/dev/null); then
        die "$TAG 릴리스가 이미 있습니다. Info.plist 버전을 올리세요."
    fi
    [ "$RELEASE_ERR" = "release not found" ] || die "릴리스를 확인하지 못했습니다: $RELEASE_ERR"

    # 탭 cask 가 아래 sed 로 고칠 수 있는 형태인지 미리 확인한다.
    TAP_DIR=$(mktemp -d)
    gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q
    [ "$(grep -c '^  version "' "$TAP_DIR/$CASK")" = 1 ] && [ "$(grep -c '^  sha256 "' "$TAP_DIR/$CASK")" = 1 ] \
        || die "$TAP_REPO/$CASK 형식이 예상과 다릅니다 (version / sha256 줄이 하나씩 있어야 합니다)."
fi

# ---- 빌드·서명 ----

rm -f "$ZIP" "$SUBMIT_ZIP"
./build.sh
codesign --verify --strict --verbose=2 "$APP"
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
[[ "$SIGN_INFO" == *$'\nAuthority=Developer ID Application'* ]] || die "Developer ID 로 서명되지 않았습니다."
[[ "$SIGN_INFO" == *$'\nTeamIdentifier='"$TEAM_ID"* ]] || die "팀 $TEAM_ID 의 인증서로 서명되지 않았습니다."
# 강화된 런타임에서 Spotify에 Apple Event를 보내려면 이 권한이 서명에 들어 있어야 한다(빠져도 공증은 통과한다).
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null) || ENTITLEMENTS=""
[[ "$ENTITLEMENTS" == *"com.apple.security.automation.apple-events"* ]] || die "서명에 Apple Events 자동화 권한(entitlement)이 없습니다."

# ---- 공증 ----

# ditto 로 묶어야 번들 메타데이터가 보존된다. 실패해도 결과를 직접 확인하도록 종료 코드를 받아 둔다.
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
NOTARY_EXIT=0
RESULT=$(xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || NOTARY_EXIT=$?
STATUS=$(plutil -extract status raw -o - - <<<"$RESULT" 2>/dev/null) || STATUS="unknown"
SUBMISSION_ID=$(plutil -extract id raw -o - - <<<"$RESULT" 2>/dev/null) || SUBMISSION_ID=""
if [ "$NOTARY_EXIT" != 0 ] || [ "$STATUS" != "Accepted" ]; then
    [ -n "$RESULT" ] && echo "$RESULT" >&2
    if [ -n "$SUBMISSION_ID" ]; then
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    die "공증 실패: status=$STATUS, exit=$NOTARY_EXIT${SUBMISSION_ID:+, id=$SUBMISSION_ID}"
fi
echo "Notarized: $SUBMISSION_ID"

# 공증 티켓을 붙인 뒤에야 배포용 zip 을 만든다.
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

echo
echo "Version: $VERSION"
echo "Commit:  $HEAD_SHA"
echo "Archive: $ZIP"
echo "SHA-256: $SHA256"

[ "$PUBLISH" = 1 ] || exit 0

# ---- 배포 ----

echo
read -r -p "$TAG 릴리스를 만들고 $TAP_REPO 를 갱신할까요? [y/N] " answer || answer=""
case "$answer" in
    y|Y) ;;
    *) echo "배포를 건너뜁니다."; exit 0 ;;
esac

# 초안으로 올려 확인을 끝낸 뒤에 공개한다. 중간에 실패하면 초안만 남는다.
gh release create "$TAG" "$ZIP" --repo "$REPO" --draft --target "$HEAD_SHA" \
    --title "Track Banner $VERSION" --generate-notes >/dev/null
DRAFT_HINT="초안 릴리스 정리: gh release delete $TAG --repo $REPO --yes"

REMOTE_DIGEST=$(gh release view "$TAG" --repo "$REPO" --json assets \
    --jq ".assets[] | select(.name == \"$(basename "$ZIP")\") | .digest") \
    || die "업로드된 파일 정보를 읽지 못했습니다. $DRAFT_HINT"
[ "$REMOTE_DIGEST" = "sha256:$SHA256" ] || die "업로드된 파일의 SHA-256 이 다릅니다: $REMOTE_DIGEST. $DRAFT_HINT"

# 탭 커밋은 미리 만들어 두고, 릴리스를 공개한 직후에 푸시한다.
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
          -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" "$TAP_DIR/$CASK"
! git -C "$TAP_DIR" diff --quiet || die "cask 가 바뀌지 않았습니다. $DRAFT_HINT"
git -C "$TAP_DIR" commit -q -am "track-banner $VERSION"

gh release edit "$TAG" --repo "$REPO" --draft=false >/dev/null
echo "Released https://github.com/$REPO/releases/tag/$TAG"

if ! git -C "$TAP_DIR" push -q; then
    KEEP_TAP_DIR=1
    die "릴리스는 공개됐지만 탭 푸시에 실패했습니다. 다시 시도: git -C $TAP_DIR push"
fi
echo "Updated $TAP_REPO: brew upgrade --cask track-banner"
