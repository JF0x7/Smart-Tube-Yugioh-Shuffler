# Troubleshooting

## App can't find the TV

- Make sure the TV and your Mac are on the same local network.
- SmartTube must be running with the remote control API enabled (default port `8497`).
- Try setting the IP manually in Settings (gear icon → Host).
- Check your router isn't isolating devices (AP isolation / client isolation).

## Pairing fails

- Make sure no other device is currently paired with the same SmartTube instance.
- Try restarting SmartTube on the TV — the pairing code is single-use.
- The pairing code expires quickly. If it times out, the app will automatically retry.

## WebSocket not connecting / no real-time updates

- The app falls back to 2-second polling when WebSocket is unavailable — playback still works.
- Ensure port `8497` is open on the TV's firewall (if any).
- Some routers block WebSocket upgrade requests. Try connecting via a different network or check router settings.

## ADB home theater features not working

- `adb` must be installed and accessible. Verify with:
  ```
  adb version
  ```
  If not found, install via `brew install android-platform-tools`.
- The TV must have ADB wireless debugging enabled and be reachable on port `5555`.
- The app is non-sandboxed — if you re-sign or sandbox it, ADB will break.
- ADB connection is optional. All YouTube playback features work without it.

## "adb" permission denied on macOS

- On macOS Sequoia+, running `adb` for the first time may trigger a Gatekeeper prompt. Allow it in System Settings → Privacy & Security.
- You may need to run `xattr -d com.apple.quarantine /opt/homebrew/bin/adb` if the binary is quarantined.

## No artwork / thumbnails not loading

- Thumbnails are fetched from YouTube's CDN. Check your internet connection.
- Some videos may not have a maxres thumbnail available — the app falls back to lower resolution artwork.

## Playback controls not responding

- The TV may be buffering or temporarily unreachable. Wait a few seconds.
- Try pressing play/pause again — the app retries on transient failures.
- Check the diagnostics panel (copy the log) to see if commands are reaching the TV.

## Copying diagnostics

Open Settings → Activity Log, then click "Copy" to copy the full connection and state history. Paste it when filing a bug report.
