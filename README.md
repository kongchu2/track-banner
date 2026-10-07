# SpotifyAlert

Spotify에서 곡이 바뀔 때 macOS 화면 오른쪽 위에 알림을 띄웁니다.
시스템 알림과 달리 앱 아이콘 자리에 **앨범 커버**가 들어갑니다.

앨범 커버는 Spotifast가 주는 URL, 또는 Spotify oEmbed API에서 가져옵니다. 로그인이나 별도 권한은 필요 없습니다.

## 빌드 & 실행

macOS 13 이상, Xcode(또는 Swift 툴체인)가 필요합니다.

```sh
./build.sh
open build/SpotifyAlert.app
```

메뉴 막대의 ♪ 아이콘에서 **로그인 시 자동 실행**을 켜거나, 아이콘을 숨기거나, 앱을 종료할 수 있습니다.
숨긴 아이콘은 앱을 한 번 더 실행하면 다시 나타납니다.
자동 실행은 켤 때의 앱 위치를 기억하므로, 먼저 `build/SpotifyAlert.app`을 `/Applications`로 옮긴 뒤 켜는 것을 권장합니다.

## 동작

- 일시정지 후 재개, 광고, 같은 곡 반복은 알림을 띄우지 않습니다.
- 알림을 클릭하면 Spotify가 앞으로 나오고, 마우스를 올려두면 사라지지 않습니다.
- macOS 26에서는 Liquid Glass 배경, 그 이전 버전에서는 블러 배경을 씁니다.

Spotify 공식 클라이언트의 기본 알림과 겹치면 Spotify 설정에서 "노래가 바뀔 때 데스크톱 알림 표시"를 꺼주세요.
