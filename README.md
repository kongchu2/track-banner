# SpotifyAlert

Spotify에서 곡이 바뀔 때 macOS 화면 오른쪽 위에 알림을 띄웁니다.
시스템 알림과 달리 앱 아이콘 자리에 **앨범 커버**가 들어갑니다.

## 지원 클라이언트

- **Spotify 공식 클라이언트** — `com.spotify.client.PlaybackStateChanged` distributed notification을 구독
- **[Spotifast](https://github.com/crmne/spotifast)** — 실행 중일 때 `Spotifast now-playing --raw`를 1초마다 호출

앨범 커버는 Spotifast가 주는 URL, 또는 Spotify oEmbed API에서 가져옵니다. 로그인이나 별도 권한은 필요 없습니다.

## 빌드 & 실행

macOS 13 이상, Xcode(또는 Swift 툴체인)가 필요합니다.

```sh
./build.sh
open build/SpotifyAlert.app
```

종료는 메뉴 막대의 ♪ 아이콘에서 합니다.

## 동작

- 일시정지 후 재개, 광고, 같은 곡 반복은 알림을 띄우지 않습니다.
- 알림을 클릭하면 Spotify가 앞으로 나오고, 마우스를 올려두면 사라지지 않습니다.
- macOS 26에서는 Liquid Glass 배경, 그 이전 버전에서는 블러 배경을 씁니다.

Spotify 공식 클라이언트의 기본 알림과 겹치면 Spotify 설정에서 "노래가 바뀔 때 데스크톱 알림 표시"를 꺼주세요.
