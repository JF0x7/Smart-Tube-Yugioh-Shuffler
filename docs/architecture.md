# Architecture

## Overview

SmartTubecontroller is a native macOS app built with **SwiftUI** and **Swift Concurrency**. It follows an **MVVM** pattern.

## Key Files

| File | Purpose |
|---|---|
| `SmartTubeSDK.swift` | SmartTube REST API client, WebSocket connection, UDP discovery, pairing |
| `SmartTubeADBBridge.swift` | ADB bridge — shells out to `adb` for HDMI CEC and hardware control |
| `ControllerViewModel.swift` | Central `ObservableObject` — manages connection, state, and all user actions |
| `NowPlayingView.swift` | Main playback view — artwork, transport, scrubber, search |
| `QueueSidebar.swift` | Left sidebar — search, Up Next feeds, queue |
| `PlaybackInspector.swift` | Right inspector — format/track pickers, chapters, theater status |
| `GlassComponents.swift` | Reusable glass-morphism UI components |
| `SettingsSheets.swift` | Connection settings and activity log |
| `ContentView.swift` | Root `NavigationSplitView` layout |
| `SmartTubecontrollerApp.swift` | App entry point |

## Communication Flow

```
┌──────────────────┐
│   SwiftUI Views  │
└───────┬──────────┘
        │ @ObservedObject
┌───────▼──────────┐
│    ViewModel     │  ← ControllerViewModel
│  (Observable)    │
└──┬───────────┬───┘
   │           │
   ▼           ▼
┌──────┐  ┌────────┐
│ SDK  │  │  ADB   │
│(REST │  │ Bridge │
│ + WS)│  │        │
└──┬───┘  └───┬────┘
   │          │
   ▼          ▼
┌──────────────────┐
│   Android TV     │
│  (SmartTube)     │
└──────────────────┘
```

- **SDK** handles YouTube-specific controls via HTTP/WebSocket on port `8497`
- **ADB Bridge** handles TV hardware controls (CEC, power, audio output) by shelling out to `adb` on port `5555`
- **ViewModel** ties them together and exposes all state to SwiftUI

## Concurrency Model

- `SmartTubeClient` is an **actor** — all network calls are serialized and thread-safe.
- `SmartTubeADBBridge` uses `Process` (subprocess) to run `adb` commands asynchronously.
- The ViewModel uses `@Published` properties and `async/await` throughout.

## No Third-Party Dependencies

Everything is built with Swift Foundation and SwiftUI. No CocoaPods, SPM, or Carthage.
