# SmartTubecontroller

A native macOS remote control for [SmartTube](https://github.com/akshaynexus/SmartTube/tree/akver) — the ad-free YouTube client for Android TV.

> **Note:** This app requires the [akver fork](https://github.com/akshaynexus/SmartTube/tree/akver) of SmartTube, which includes the custom REST API used for communication. The official SmartTube build does not have this API.

<p align="center">
  <img src="screenshots/main_screenshot_hero.png" alt="SmartTubecontroller" width="800" />
</p>

## Features

- **Auto-connect & Pairing** — discovers TVs via UDP broadcast or subnet scan, pairs with a 6-digit code, stores the token
- **Real-time Playback** — WebSocket pushes live player state (position, play state, current video) with a polling fallback
- **Now Playing** — full-bleed artwork, title/channel overlay, transport controls, scrubber with chapter markers
- **Search** — type a YouTube URL, video ID, or search query; results show instantly
- **Queue Management** — browse "Up Next" feeds (recommended / related), add to queue, play next, remove
- **Playback Inspector** — switch video quality, audio language, subtitles; list and seek chapters
- **TV Volume** — draggable slider (0–100), mute toggle, volume up/down
- **Home Theater Controls** — subwoofer level, rear speaker level, sound mode, spatial audio toggle, audio output switching (ADB/CEC)
- **Power Toggle** — turn the TV on or off remotely
- **Diagnostics** — copyable activity log and connection/player/theater state dump

## Screenshots

<p align="center">
  <img src="screenshots/main_screenshot.png" alt="Main playback view" width="700" />
</p>
<p align="center">
  <img src="screenshots/main_screenshot_with_queue.png" alt="Queue sidebar" width="700" />
</p>
<p align="center">
  <img src="screenshots/main_screenshot_with_tracks_quality.png" alt="Track and quality picker" width="700" />
</p>

## What it does

SmartTubecontroller talks to a SmartTube instance running on your Android TV (or Sony Bravia) over the local network. It handles **YouTube playback** and **home theater hardware** through two separate channels:

| Channel | Default Port | Used for |
|---|---|---|
| **SmartTube REST API** | `8497` | Discovery, pairing, playback transport, seeking, volume, queue, search, chapters, track/format selection, d-pad / voice |
| **ADB (Android Debug Bridge)** | `5555` | HDMI CEC home theater control (subwoofer, rear speakers, sound mode, immersive audio), TV power, audio output switching |

## Requirements

- macOS 26.5 (Tahoe) or later
- Xcode 26.5
- A SmartTube-capable Android TV on the same local network
- _(Optional)_ Android platform-tools (`adb`) for home theater features:
  ```
  brew install android-platform-tools
  ```

## Building SmartTube (akver fork)

The official SmartTube APK does not include the REST API this controller depends on. You must build the fork:

1. Clone the fork and checkout the `akver` branch:
   ```
   git clone https://github.com/akshaynexus/SmartTube.git
   cd SmartTube
   git checkout akver
   ```
2. Build the APK following the SmartTube [build instructions](https://github.com/akshaynexus/SmartTube/tree/akver#build).
3. Sideload the APK onto your Android TV via `adb` or a USB drive.

## Build & Run

1. Clone the repo
2. Open `SmartTubecontroller.xcodeproj` in Xcode
3. Change the development team to your own (the default team is pre-configured)
4. Build & Run (⌘R)

## Documentation

- [Troubleshooting](docs/troubleshooting.md)
- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)

## License

[MIT](LICENSE) — akshaynexus / Akshay CM
