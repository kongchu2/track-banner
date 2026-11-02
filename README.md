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

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, then commit and push.
2. Run:

   ```sh
   scripts/release.sh
   ```

The script builds a Developer ID-signed, notarized, stapled `build/TrackBanner-<version>.zip` from a clean working tree.
After you confirm, it uploads a draft `v<version>` GitHub release and checks the uploaded file's SHA-256.
Then it publishes the release and updates `version` and `sha256` in [kongchu2/homebrew-tap](https://github.com/kongchu2/homebrew-tap).
Publishing also requires HEAD to match `origin/main` and the tag not to exist yet; these checks run before the build.

`scripts/release.sh --no-publish` only builds and notarizes, and works on any clean commit.

It needs a notarytool keychain profile named `trackbanner` (`xcrun notarytool store-credentials trackbanner ...`).
