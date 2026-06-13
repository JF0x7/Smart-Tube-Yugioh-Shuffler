# Configuration

All settings are stored in `UserDefaults` and editable from the Settings sheet (gear icon in the toolbar).

## Connection Settings

| Key | Default | Description |
|---|---|---|
| `smarttube.host` | `127.0.0.1` | IP address of the TV running SmartTube |
| `smarttube.port` | `8497` | SmartTube REST API port |
| `smarttube.token` | `""` | Bearer token — obtained automatically via pairing |
| `smarttube.bridge.host` | `""` | ADB host override. Leave blank to use the same host as the API |
| `smarttube.bridge.port` | `5555` | ADB port |
| `smarttube.playervolume.enabled` | `false` | Show the ExoPlayer internal volume slider |
| `smarttube.upnext.feed` | `"Recommended"` | Up Next feed source (`Recommended` or `Related`) |

## Connection Flow

1. App pings `http://<host>:8497/api/system/ping`
2. If `pairing_required` is false (open mode), connects directly
3. If a saved token exists, probes it against the queue endpoint
4. Otherwise, performs automatic pairing — gets a code via `GET /api/pair`, verifies via `POST /api/pair/verify`, stores the token
5. ADB connection is attempted in parallel (if `adb` is installed and the TV is reachable on port `5555`)
6. Opens a WebSocket for real-time state updates; starts 2-second polling as fallback

## SmartTube REST API

This controller requires the [akver fork](https://github.com/akshaynexus/SmartTube/tree/akver) of SmartTube. The official build does not expose the REST API.

The app communicates over HTTP on port `8497`. Key endpoints used:

- `GET /api/system/ping` — connection check
- `GET /api/pair` / `POST /api/pair/verify` — pairing
- `GET /api/player/play`, `POST /api/player/pause`, `POST /api/player/seek` — transport
- `GET /api/queue` — queue state
- `GET /api/search` — search YouTube
- `GET /api/chapters` — chapter list
- `ws://<host>:8497/ws?token=<token>` — real-time state WebSocket

## ADB Commands Used

The app runs `adb` commands over the network for hardware control:

- `adb connect <host>:5555` — connect to TV
- `adb shell input keyevent KEYCODE_POWER` — power toggle
- `adb shell cmd hdmi_control vendorcommand <data>` — CEC commands
- `adb shell dumpsys hdmi_control` — read CEC state
- `adb shell getprop ro.product.model` — identify TV model
