# Track Banner for Spotify

Shows a banner in the top-right corner of your macOS screen whenever the track changes in Spotify.
Unlike system notifications, the **album cover** takes the place of the app icon.

Album art comes from the URL provided by Spotifast, or from the Spotify oEmbed API. No login or extra permissions are required.

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
