# Track Banner for Spotify

Shows a banner in the top-right corner of your macOS screen whenever the track changes in Spotify.
Unlike system notifications, the **album cover** takes the place of the app icon.

Album art comes from the URL provided by Spotifast, or from the Spotify oEmbed API. No login or extra permissions are required.

## Install

```sh
brew install kongchu2/tap/track-banner
```

Or download the latest `TrackBanner-<version>.zip` from [Releases](https://github.com/kongchu2/track-banner/releases), unzip it, and move `TrackBanner.app` to `/Applications`.
The app is signed with Developer ID and notarized by Apple.

## Build & Run

Requires macOS 13 or later and Xcode (or a Swift toolchain).

```sh
./build.sh
open build/TrackBanner.app
```

From the banner-shaped icon in the menu bar you can turn on **Launch at Login**, hide the icon, or quit the app.
A hidden icon comes back when you open the app again.
Launch at Login remembers where the app was when you turned it on, so move `build/TrackBanner.app` to `/Applications` first.

## Behavior

- No banner for resuming after a pause, ads, or repeating the same track.
- The banner disappears after 2.5 seconds. Hovering keeps it on screen and shows a close button in the top-left corner.
- Clicking the banner brings Spotify to the front; the close button just dismisses it.
- Uses a Liquid Glass background on macOS 26 and a blurred background on earlier versions.

If this overlaps with the official Spotify client's own notifications, turn off "Show desktop notifications when the song changes" in Spotify's settings.

## Release

```sh
scripts/release.sh
```

Builds a Developer ID-signed, notarized, stapled `build/TrackBanner-<version>.zip` and prints its SHA-256.
It needs a notarytool keychain profile named `trackbanner` (`xcrun notarytool store-credentials trackbanner ...`).
Upload the zip to a GitHub release tagged `v<version>`, then update `version` and `sha256` in [kongchu2/homebrew-tap](https://github.com/kongchu2/homebrew-tap).
