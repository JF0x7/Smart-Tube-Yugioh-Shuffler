//
//  ContentView.swift
//  SmartTubecontroller
//
//  Unified macOS player-style controller for SmartTube Remote API + ADB Bridge.
//  Requires SmartTubeSDK.swift and SmartTubeADBBridge.swift in the same Xcode target.
//

import SwiftUI
import Combine
import AppKit

struct RemoteFormat: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case video
        case audio
        case subtitle
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let selected: Bool
}

@MainActor
final class SmartTubeControllerViewModel: ObservableObject {
    @Published var host: String
    @Published var apiPort: String
    @Published var token: String
    @Published var bridgeHost: String
    @Published var bridgePort: String

    @Published var isAPIConnected: Bool = false
    @Published var isRealtimeConnected: Bool = false
    @Published var isBridgeConnected: Bool = false
    @Published var isBusy: Bool = false

    @Published var phase: String = "Ready"
    @Published var bridgePhase: String = "Bridge idle"
    @Published var lastError: String?

    @Published var player: PlayerState? {
        // Every state update (realtime WS + poll) carries the selected tracks —
        // apply them so quality/audio/subtitle pickers stay live without refetching.
        didSet { self.applySelectedTracks() }
    }
    @Published var queue: [QueueItem] = []
    @Published var suggestions: [QueueItem] = []
    @Published var recommended: [QueueItem] = []
    @Published var searchResults: [QueueItem] = []
    @Published var isSearching: Bool = false
    @Published var theater: TheaterState?
    @Published var cec: SmartTubeCECState?
    @Published var videoFormats: [RemoteFormat] = []
    @Published var audioFormats: [RemoteFormat] = []
    @Published var subtitleFormats: [RemoteFormat] = []
    @Published var logs: [String] = []

    private var client: SmartTubeClient?
    private var bridge: SmartTubeADBBridgeClient?
    private var realtime: SmartTubeWebSocketClient?
    private var pollTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        self.host = defaults.string(forKey: "smarttube.host") ?? "127.0.0.1"
        self.apiPort = defaults.string(forKey: "smarttube.port") ?? "8497"
        self.token = defaults.string(forKey: "smarttube.token") ?? ""
        // Blank ADB host means "same as the API host"; ADB-over-network uses port 5555.
        self.bridgeHost = defaults.string(forKey: "smarttube.bridge.host") ?? ""
        self.bridgePort = defaults.string(forKey: "smarttube.bridge.port") ?? "5555"
        self.playerVolumeEnabled = defaults.bool(forKey: "smarttube.playervolume.enabled")
    }

    /// Optional secondary control for ExoPlayer's internal volume (normally 100%).
    @Published var playerVolumeEnabled: Bool = false {
        didSet { self.defaults.set(self.playerVolumeEnabled, forKey: "smarttube.playervolume.enabled") }
    }

    var playbackVolumePercent: Int { Int(((self.player?.volume ?? 1) * 100).rounded()) }

    var apiPortInt: Int { Int(self.apiPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 8497 }
    var bridgePortInt: Int { Int(self.bridgePort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5555 }

    /// The ADB target host: an explicit override, or the API/TV host when left blank.
    var adbHost: String {
        let override = self.bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? self.host : override
    }

    var title: String {
        if let value = self.player?.video?.title, !value.isEmpty { return value }
        return self.isAPIConnected ? "Connected — no video loaded" : "Not connected"
    }

    var subtitle: String {
        if let value = self.player?.video?.author, !value.isEmpty { return value }
        return "\(self.host):\(self.apiPortInt)"
    }

    var thumbnailURL: URL? {
        guard let raw = self.player?.video?.thumbnailURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// YouTube's maxres thumbnail (1280×720). Not every video has one — callers must
    /// fall back to `thumbnailURL` on failure.
    var hiResThumbnailURL: URL? {
        guard let id = self.player?.video?.videoId, !id.isEmpty else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
    }

    var stateText: String { self.player?.state.rawValue.capitalized ?? "Idle" }
    var isPlaying: Bool { self.player?.state == .playing }
    var isBuffering: Bool { self.player?.state == .buffering }
    var positionMs: Int { self.player?.positionMs ?? 0 }
    var durationMs: Int { self.player?.durationMs ?? self.player?.video?.durationMs ?? 0 }

    var diagnostics: String {
        """
        SmartTube controller diagnostics
        API: \(self.host):\(self.apiPortInt)
        Bridge: \(self.bridgeHost):\(self.bridgePortInt)
        Token: \(self.redactedToken)
        Connected: api=\(self.isAPIConnected), realtime=\(self.isRealtimeConnected), bridge=\(self.isBridgeConnected)
        Phase: \(self.phase)
        Bridge phase: \(self.bridgePhase)
        Player: \(self.player?.state.rawValue ?? "nil") pos=\(self.positionMs) dur=\(self.durationMs)
        Video: \(self.player?.video?.title ?? "nil")
        Theater: volume=\(self.theater?.volume.description ?? "nil") muted=\(self.theater?.muted.description ?? "nil") output=\(self.theater?.audioOutput ?? "nil")
        CEC: output=\(self.cec?.audioOutput.rawValue ?? "nil") sub=\(self.cec?.subwooferLevel?.description ?? "nil") rear=\(self.cec?.rearLevel?.description ?? "nil") immersive=\(self.cec?.immersiveAEEnabled?.description ?? "nil") mode=\(self.cec?.soundMode?.rawValue ?? "nil")
        Last error: \(self.lastError ?? "nil")

        Log:
        \(self.logs.joined(separator: "\n"))
        """
    }

    var redactedToken: String {
        let value = self.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 10 else { return value.isEmpty ? "none" : value }
        return "\(value.prefix(6))…\(value.suffix(4))"
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        let line = "[\(formatter.string(from: Date()))] \(message)"
        self.logs.append(line)
        if self.logs.count > 500 {
            self.logs.removeFirst(self.logs.count - 500)
        }
    }

    func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(self.logs.joined(separator: "\n"), forType: .string)
        self.log("Copied logs")
    }

    func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(self.diagnostics, forType: .string)
        self.log("Copied diagnostics")
    }

    func saveSettings() {
        self.defaults.set(self.host, forKey: "smarttube.host")
        self.defaults.set(self.apiPort, forKey: "smarttube.port")
        self.defaults.set(self.token, forKey: "smarttube.token")
        self.defaults.set(self.bridgeHost, forKey: "smarttube.bridge.host")
        self.defaults.set(self.bridgePort, forKey: "smarttube.bridge.port")
    }

    func autoConnect() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }

        self.lastError = nil
        self.phase = "Connecting…"
        self.log("Starting auto connect")

        await self.connectBridgeIfPossible()
        if let bridge = self.bridge {
            do {
                let info = try await bridge.smartTubeAutoconnect()
                self.host = info.host
                self.apiPort = String(info.port)
                self.log("Forwarded SmartTube API from \(info.model) to \(info.host):\(info.port)")
            } catch {
                self.log("ADB forward skipped: \(error.localizedDescription)")
            }
        }

        await self.connectAPIAndPairIfNeeded()
    }

    func manualConnect() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }
        self.lastError = nil
        self.log("Manual connect")
        await self.connectAPIAndPairIfNeeded()
    }

    func connectBridgeIfPossible() async {
        let host = self.adbHost
        self.bridgePhase = "Connecting ADB…"
        // Keep the client around even when the first ping fails — it reconnects
        // lazily, so the next theater command retries instead of erroring with
        // "not connected" forever.
        let b = try? SmartTubeADBBridgeClient(host: host, port: self.bridgePortInt)
        self.bridge = b
        do {
            guard let b else { throw SmartTubeADBBridgeError.adbNotFound }
            b.connect()
            _ = try await b.ping()
            self.isBridgeConnected = true
            self.bridgePhase = "ADB connected"
            self.log("ADB connected to \(host):\(self.bridgePortInt)")
        } catch {
            self.isBridgeConnected = false
            self.bridgePhase = "ADB unavailable — will retry on use"
            self.log("ADB unavailable: \(error.localizedDescription)")
        }
    }

    func connectAPIAndPairIfNeeded() async {
        self.saveSettings()
        let plainClient = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt))

        var pairingRequired = true
        do {
            let ping = try await plainClient.ping()
            pairingRequired = ping.pairingRequired ?? true
            self.phase = "Ping OK: \(ping.deviceName)"
            self.log("Ping OK: \(ping.deviceName)\(pairingRequired ? "" : " (open mode)")")
        } catch {
            self.isAPIConnected = false
            self.phase = "API connection failed"
            self.lastError = error.localizedDescription
            self.log("API connection failed: \(error.localizedDescription)")
            return
        }

        let savedToken = self.token.trimmingCharacters(in: .whitespacesAndNewlines)

        // Open mode: the TV accepts any local connection — connect directly, no pairing.
        // A non-empty placeholder token keeps the auth header/WS query populated; the
        // server ignores it in open mode.
        if !pairingRequired {
            let openToken = savedToken.isEmpty ? "open" : savedToken
            let authed = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: openToken))
            do {
                // Probe with the queue endpoint: /api/player returns 503 when no video
                // is loaded, which is NOT an auth failure.
                _ = try await authed.getQueue()
                self.token = openToken
                self.client = authed
                self.isAPIConnected = true
                self.phase = "Connected"
                self.log("Connected (open mode, no pairing)")
                self.saveSettings()
                await self.afterConnected()
                return
            } catch {
                self.log("Open-mode connect failed, falling back: \(error.localizedDescription)")
            }
        }

        if !savedToken.isEmpty {
            let authed = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: savedToken))
            do {
                // Queue probe: works even when the player is idle (503).
                _ = try await authed.getQueue()
                self.client = authed
                self.isAPIConnected = true
                self.phase = "Connected"
                self.log("Saved token accepted")
                await self.afterConnected()
                return
            } catch {
                self.log("Saved token rejected: \(error.localizedDescription)")
            }
        }

        do {
            self.phase = "Pairing automatically…"
            let pair = try await plainClient.getPairCode()
            let verified = try await self.verifyPairCodeRobust(client: plainClient, code: pair.code)
            self.token = verified.token
            self.client = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: verified.token))
            self.isAPIConnected = true
            self.phase = "Paired with \(verified.deviceName)"
            self.log("Auto pair OK")
            self.saveSettings()
            await self.afterConnected()
        } catch {
            self.isAPIConnected = false
            self.phase = "Pairing failed"
            self.lastError = "Pairing failed: \(error.localizedDescription)"
            self.log(self.lastError ?? "Pairing failed")
        }
    }

    private func verifyPairCodeRobust(client: SmartTubeClient, code: String) async throws -> PairVerifyResponse {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { $0.isNumber }
        var candidates: [String] = []

        func add(_ value: String) {
            if !value.isEmpty && !candidates.contains(value) { candidates.append(value) }
        }

        add(trimmed)
        if digits.count == 6 {
            add(digits)
            add(String(digits.prefix(3)) + " " + String(digits.suffix(3)))
        }

        var lastError: Error?
        for candidate in candidates {
            do { return try await client.verifyPairCode(candidate) }
            catch { lastError = error }
        }
        throw lastError ?? SmartTubeError.emptyResponse
    }

    private func afterConnected() async {
        self.saveSettings()
        await self.refreshAll()
        self.connectRealtime()
        self.startPollingFallback()
    }

    func refreshAll() async {
        guard let c = self.client else { return }

        do {
            self.player = try await c.getPlayer()
            self.log("Player refreshed: \(self.player?.state.rawValue ?? "unknown")")
        } catch {
            self.log("Player refresh failed: \(error.localizedDescription)")
        }

        do {
            self.queue = Self.stableOrderMerge(old: self.queue, new: try await c.getQueue())
            self.log("Queue refreshed: \(self.queue.count) items")
        } catch {
            self.log("Queue refresh failed: \(error.localizedDescription)")
        }

        do {
            self.theater = try await c.getTheater()
            self.log("Theater refreshed: volume \(self.theater?.volume ?? 0)")
        } catch {
            self.log("Theater refresh failed: \(error.localizedDescription)")
        }

        await self.refreshTracks()
        await self.refreshCEC()
        await self.refreshSuggestions()
        await self.refreshRecommended()
    }

    private var lastPollError: String?
    private var lastVideoId: String?

    func refreshFast() async {
        guard let c = self.client else { return }
        do {
            self.player = try await c.getPlayer()
            if self.lastPollError != nil {
                self.lastPollError = nil
                self.log("Player poll recovered")
            }
            // The TV's suggestion list belongs to the CURRENT video — refresh ours when
            // it changes, or clicking a recommendation plays a stale/wrong entry.
            let videoId = self.player?.video?.videoId
            if videoId != self.lastVideoId {
                self.lastVideoId = videoId
                await self.refreshSuggestions(replace: true)
                await self.refreshTracks()
            }
        } catch {
            // Log once per distinct error so decode/transport failures are visible
            // without spamming every 2s poll.
            let message = error.localizedDescription
            if message != self.lastPollError {
                self.lastPollError = message
                self.log("Player poll failed: \(message)")
            }
        }
        do { self.queue = Self.stableOrderMerge(old: self.queue, new: try await c.getQueue()) } catch { }
        do { self.theater = try await c.getTheater() } catch { }
    }

    /// Re-applies the previous on-screen order to a freshly fetched list. SmartTube's
    /// Playlist moves replayed videos to the end and the recommended feed reshuffles
    /// on every fetch, so a raw replacement makes rows jump around under the 2s poll.
    /// Items keep their old position (with refreshed data, e.g. is_current); genuinely
    /// new items append in server order; vanished items drop out.
    static func stableOrderMerge(old: [QueueItem], new: [QueueItem]) -> [QueueItem] {
        guard !old.isEmpty, !new.isEmpty else { return new }
        var fresh: [String: QueueItem] = [:]
        for item in new {
            guard let id = item.videoId else { continue }
            // keep the first occurrence if the server ever sends duplicates
            if fresh[id] == nil { fresh[id] = item }
        }
        var merged: [QueueItem] = []
        for item in old {
            guard let id = item.videoId, let updated = fresh.removeValue(forKey: id) else { continue }
            merged.append(updated)
        }
        for item in new {
            if let id = item.videoId {
                guard let remaining = fresh.removeValue(forKey: id) else { continue }
                merged.append(remaining)
            } else {
                // no videoId to match on — keep it rather than silently dropping it
                merged.append(item)
            }
        }
        return merged
    }

    func refreshTracks() async {
        guard let c = self.client else { return }
        do {
            self.videoFormats = try await self.loadFormats(client: c, path: "/api/player/formats/video", kind: .video)
            self.audioFormats = try await self.loadFormats(client: c, path: "/api/player/formats/audio", kind: .audio)
            self.subtitleFormats = try await self.loadFormats(client: c, path: "/api/player/formats/subtitle", kind: .subtitle)
            self.log("Tracks refreshed")
        } catch {
            self.log("Tracks refresh failed: \(error.localizedDescription)")
        }
    }

    private func loadFormats(client: SmartTubeClient, path: String, kind: RemoteFormat.Kind) async throws -> [RemoteFormat] {
        let json = try await client.rawJSON(method: "GET", path: path)
        guard case .array(let rows) = json else { return [] }

        return rows.compactMap { value in
            guard case .object(let obj) = value else { return nil }
            guard let id = Self.string(obj["format_id"]), !id.isEmpty else { return nil }

            let label = Self.string(obj["label"])
            let codec = Self.string(obj["codec"])
            let language = Self.string(obj["language_label"]) ?? Self.string(obj["language"])
            let height = Self.int(obj["height"])
            let bitrate = Self.int(obj["bitrate"])
            let selected = Self.bool(obj["is_selected"]) ?? false

            let title: String
            switch kind {
            case .video:
                title = label ?? (height.map { "\($0)p" } ?? id)
            case .audio:
                title = language ?? label ?? codec ?? id
            case .subtitle:
                title = language ?? label ?? id
            }

            let bits = [codec, bitrate.map { "\($0 / 1000) kbps" }].compactMap { $0 }
            return RemoteFormat(id: id, kind: kind, title: title, subtitle: bits.joined(separator: " · "), selected: selected)
        }
    }

    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let raw) = value else { return nil }
        return raw.isEmpty ? nil : raw
    }

    static func int(_ value: JSONValue?) -> Int? {
        guard case .number(let raw) = value else { return nil }
        return Int(raw)
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let raw) = value else { return nil }
        return raw
    }

    private func applySelectedTracks() {
        guard let selected = self.player?.selectedTracks else { return }

        func mark(_ list: [RemoteFormat], id: String?) -> [RemoteFormat] {
            guard let id, !id.isEmpty, list.contains(where: { $0.id == id }) else { return list }
            guard list.first(where: { $0.selected })?.id != id else { return list } // already current
            return list.map {
                RemoteFormat(id: $0.id, kind: $0.kind, title: $0.title, subtitle: $0.subtitle, selected: $0.id == id)
            }
        }

        self.videoFormats = mark(self.videoFormats, id: selected.video?.formatId)
        self.audioFormats = mark(self.audioFormats, id: selected.audio?.formatId)
        self.subtitleFormats = mark(self.subtitleFormats, id: selected.subtitle?.formatId)
    }

    func refreshCEC() async {
        guard let b = self.bridge else { return }
        do {
            let parsed = try await b.getParsedCECState()
            self.cec = Self.cleanCEC(parsed)
            // A successful CEC read proves the lazy ADB connection is up.
            if !self.isBridgeConnected {
                self.isBridgeConnected = true
                self.bridgePhase = "ADB connected"
            }
            self.log("CEC refreshed")
        } catch {
            self.log("CEC refresh failed: \(error.localizedDescription)")
        }
    }

    static func cleanCEC(_ state: SmartTubeCECState) -> SmartTubeCECState {
        var copy = state
        if copy.subwooferLevel == 255 { copy.subwooferLevel = nil }
        if copy.rearLevel == 255 { copy.rearLevel = nil }
        return copy
    }

    func connectRealtime() {
        self.realtime?.disconnect()
        guard !self.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let socket = SmartTubeWebSocketClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: self.token))
        socket.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .hello(_, let deviceName):
                    self.isRealtimeConnected = true
                    self.log("Realtime connected\(deviceName.map { " to \($0)" } ?? "")")
                case .stateUpdate(let state):
                    self.player = state
                    self.isRealtimeConnected = true
                case .json(let json):
                    self.log("Realtime JSON: \(String(describing: json))")
                }
            }
        }
        socket.onError = { [weak self] error in
            Task { @MainActor in
                self?.isRealtimeConnected = false
                self?.log("Realtime warning: \(error.localizedDescription)")
            }
        }
        socket.onClose = { [weak self, weak socket] in
            Task { @MainActor in
                guard let self else { return }
                self.isRealtimeConnected = false
                // Only auto-reconnect if this socket is still the active one
                // (a manual reconnect replaces self.realtime first).
                guard self.realtime === socket else { return }
                self.log("Realtime closed; reconnecting in 3s (polling continues)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.isAPIConnected && !self.isRealtimeConnected && self.realtime === socket {
                    self.connectRealtime()
                }
            }
        }

        do {
            try socket.connect()
            self.realtime = socket
            self.isRealtimeConnected = true
            self.log("Realtime connecting")
        } catch {
            self.isRealtimeConnected = false
            self.log("Realtime unavailable: \(error.localizedDescription)")
        }
    }

    func startPollingFallback() {
        self.pollTask?.cancel()
        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refreshFast()
            }
        }
    }

    func run(_ label: String, _ operation: @MainActor @escaping () async throws -> Void) async {
        guard !self.isBusy else { return }
        self.isBusy = true
        self.phase = label
        self.log(label)
        defer { self.isBusy = false }
        do {
            try await operation()
            self.phase = "\(label) OK"
            self.log("\(label) OK")
            await self.refreshFast()
        } catch {
            self.lastError = "\(label) failed: \(error.localizedDescription)"
            self.phase = self.lastError ?? "Failed"
            self.log("Failed: \(self.lastError ?? error.localizedDescription)")
        }
    }

    func togglePlay() async {
        await self.run("Play/Pause") {
            try await self.clientOrThrow().toggle()
        }
    }

    func play() async {
        await self.run("Play") {
            try await self.clientOrThrow().play()
        }
    }

    func pause() async {
        await self.run("Pause") {
            try await self.clientOrThrow().pause()
        }
    }

    func next() async {
        await self.run("Next") {
            try await self.clientOrThrow().next()
        }
    }

    func previous() async {
        await self.run("Previous") {
            try await self.clientOrThrow().previous()
        }
    }

    func seek(ms: Int) async {
        await self.run("Seek") {
            try await self.clientOrThrow().seek(positionMs: max(ms, 0))
        }
    }

    func seekBy(seconds: Int) async {
        await self.seek(ms: max(self.positionMs + seconds * 1000, 0))
    }

    /// Sets ExoPlayer's internal volume (0–100). Hidden behind the
    /// "player volume" setting — it's a pre-amp gain, secondary to TV volume.
    func setPlaybackVolume(percent: Int) async {
        let value = min(max(Double(percent) / 100.0, 0), 1)
        await self.run("Set player volume") {
            try await self.clientOrThrow().setVolume(value)
        }
    }

    /// Sets the TV / audio-system volume (0–100) — the primary volume control.
    func setTVVolume(percent: Int) async {
        await self.run("Set TV volume") {
            try await self.clientOrThrow().setTheaterVolume(percent)
        }
    }

    func tvVolumeUp() async {
        await self.run("TV volume up") {
            try await self.clientOrThrow().theaterVolumeUp()
        }
    }

    func tvVolumeDown() async {
        await self.run("TV volume down") {
            try await self.clientOrThrow().theaterVolumeDown()
        }
    }

    func toggleTVMute() async {
        await self.run("Toggle TV mute") {
            try await self.clientOrThrow().toggleTheaterMute()
        }
    }

    func openVideo(_ input: String) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await self.run("Open video") {
            if text.contains("/") || text.contains("youtube.com") || text.contains("youtu.be") {
                try await self.clientOrThrow().openURL(text)
            } else {
                try await self.clientOrThrow().openVideoId(text)
            }
        }
    }

    func searchAndPlay(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await self.run("Search and play") {
            try await self.clientOrThrow().searchAndPlay(text)
        }
    }

    /// Fetches search results for the picker without touching playback. Quiet on
    /// failure (no isBusy/phase churn) — this runs on every keystroke debounce.
    func search(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let c = self.client else {
            self.searchResults = []
            return
        }
        self.isSearching = true
        defer { self.isSearching = false }
        do {
            self.searchResults = try await c.searchResults(text)
        } catch is CancellationError {
            // superseded by a newer keystroke
        } catch {
            self.log("Search failed: \(error.localizedDescription)")
            self.searchResults = []
        }
    }

    func clearSearchResults() {
        self.searchResults = []
    }

    func playVideoId(_ videoId: String) async {
        await self.run("Play video") {
            try await self.clientOrThrow().openVideoId(videoId)
        }
    }

    func addToQueue(_ input: String) async {
        let id = Self.extractVideoId(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !id.isEmpty else { return }
        await self.run("Add to queue") {
            try await self.clientOrThrow().addToQueue(videoId: id)
        }
    }

    func playNext(_ input: String) async {
        let id = Self.extractVideoId(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !id.isEmpty else { return }
        await self.run("Play next") {
            try await self.clientOrThrow().playNext(videoId: id)
        }
    }

    func removeQueueItem(_ item: QueueItem) async {
        guard let id = item.videoId else { return }
        await self.run("Remove queue item") {
            try await self.clientOrThrow().removeFromQueue(videoId: id)
        }
    }

    func clearQueue() async {
        await self.run("Clear queue") {
            try await self.clientOrThrow().clearQueue()
        }
    }

    /// `replace: true` swaps the list wholesale — used when the playing video changes
    /// and the related list belongs to a new video. Default keeps on-screen order stable.
    func refreshSuggestions(replace: Bool = false) async {
        guard let c = self.client else { return }
        do {
            let fetched = try await c.getSuggestions()
            self.suggestions = replace ? fetched : Self.stableOrderMerge(old: self.suggestions, new: fetched)
            self.log("Suggestions refreshed: \(self.suggestions.count)")
        } catch {
            self.log("Suggestions refresh failed: \(error.localizedDescription)")
        }
    }

    // Play a related-videos suggestion. By video ID when we have one (immune to the
    // list refreshing under us); index is only the legacy fallback.
    func playSuggestion(_ item: QueueItem, at index: Int) async {
        await self.run("Play suggestion") {
            if let id = item.videoId, !id.isEmpty {
                try await self.clientOrThrow().playSuggestion(videoId: id)
            } else {
                try await self.clientOrThrow().playSuggestion(index: index)
            }
        }
        await self.refreshFast()
    }

    // The user's Home recommendations (server-side cached) — unlike `suggestions`,
    // which are the related videos of whatever is currently playing.
    func refreshRecommended() async {
        guard let c = self.client else { return }
        do {
            self.recommended = Self.stableOrderMerge(old: self.recommended, new: try await c.getRecommended())
            self.log("Recommended refreshed: \(self.recommended.count)")
        } catch {
            self.log("Recommended refresh failed: \(error.localizedDescription)")
        }
    }

    // Recommended items are played by video ID, so the list never goes stale-by-index.
    func playRecommended(_ item: QueueItem) async {
        guard let id = item.videoId else { return }
        await self.run("Play recommended") {
            try await self.clientOrThrow().openVideoId(id)
        }
        await self.refreshFast()
    }

    func setVideoFormat(_ id: String) async {
        await self.run("Set video format") {
            try await self.clientOrThrow().setVideoFormat(id)
        }
        await self.refreshTracks()
    }

    func setAudioFormat(_ id: String) async {
        await self.run("Set audio format") {
            try await self.clientOrThrow().setAudioFormat(id)
        }
        await self.refreshTracks()
    }

    func setSubtitleFormat(_ id: String?) async {
        await self.run("Set subtitles") {
            try await self.clientOrThrow().setSubtitleFormat(id)
        }
        await self.refreshTracks()
    }

    func setHomeTheater() async {
        await self.run("Set home theater speakers") {
            _ = try await self.bridgeOrThrow().setHomeTheaterSpeakers()
        }
        await self.refreshCEC()
    }

    func setTVSpeakers() async {
        await self.run("Set TV speakers") {
            _ = try await self.bridgeOrThrow().setTVSpeakers()
        }
        await self.refreshCEC()
    }

    func setSubwoofer(_ level: Double) async {
        await self.run("Set subwoofer") {
            try await self.bridgeOrThrow().setSubwooferLevel(Int(level.rounded()))
        }
        await self.refreshCEC()
    }

    func setRear(_ level: Double) async {
        await self.run("Set rear level") {
            try await self.bridgeOrThrow().setRearLevel(Int(level.rounded()))
        }
        await self.refreshCEC()
    }

    func setImmersive(_ enabled: Bool) async {
        await self.run("Set Immersive AE") {
            try await self.bridgeOrThrow().setImmersiveAE(enabled)
        }
        await self.refreshCEC()
    }

    func setSoundMode(_ mode: SmartTubeSoundMode) async {
        await self.run("Set sound mode") {
            try await self.bridgeOrThrow().setSoundMode(mode)
        }
        await self.refreshCEC()
    }

    func powerToggle() async {
        await self.run("Power toggle") {
            if let bridge = self.bridge {
                try await bridge.powerToggle()
            } else {
                try await self.clientOrThrow().toggleTheaterPower()
            }
        }
    }

    private func clientOrThrow() throws -> SmartTubeClient {
        guard let client = self.client else { throw SmartTubeError.missingToken }
        return client
    }

    private func bridgeOrThrow() throws -> SmartTubeADBBridgeClient {
        guard let bridge = self.bridge else { throw SmartTubeADBBridgeError.notConnected }
        return bridge
    }

    static func extractVideoId(_ input: String) -> String {
        guard !input.isEmpty else { return "" }
        if let url = URL(string: input), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
            if url.host?.contains("youtu.be") == true {
                return url.pathComponents.dropFirst().first ?? input
            }
        }
        return input
    }

    static func formatTime(_ ms: Int) -> String {
        let total = max(ms / 1000, 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

struct ContentView: View {
    @StateObject private var vm = SmartTubeControllerViewModel()
    @State private var showInspector = true
    @State private var showSettings = false
    @State private var showLogs = false

    var body: some View {
        NavigationSplitView {
            QueueSidebar(vm: self.vm)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            NowPlayingView(vm: self.vm)
                .frame(minWidth: 420, minHeight: 480)
        }
        .navigationTitle("SmartTube")
        .navigationSubtitle(self.vm.player?.video?.title ?? "")
        .inspector(isPresented: self.$showInspector) {
            PlaybackInspector(vm: self.vm)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ConnectionStatus(vm: self.vm)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if self.vm.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await self.vm.autoConnect() }
                } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("Auto-connect and pair")
                .keyboardShortcut("r", modifiers: [.command])

                Menu {
                    Button("Connection Settings…") { self.showSettings = true }
                    Button("Reconnect Manually") { Task { await self.vm.manualConnect() } }
                    Divider()
                    Button("Show Activity Log…") { self.showLogs = true }
                    Button("Copy Logs") { self.vm.copyLogs() }
                    Button("Copy Diagnostics") { self.vm.copyDiagnostics() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }

                Button {
                    self.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle the playback inspector")
            }
        }
        .sheet(isPresented: self.$showSettings) {
            ConnectionSettingsSheet(vm: self.vm)
        }
        .sheet(isPresented: self.$showLogs) {
            ActivityLogSheet(vm: self.vm)
        }
        .task {
            await self.vm.autoConnect()
        }
    }
}

// MARK: - Connection status (toolbar)

private struct ConnectionStatus: View {
    @ObservedObject var vm: SmartTubeControllerViewModel

    var body: some View {
        HStack(spacing: 7) {
            indicator("API", active: self.vm.isAPIConnected, help: "SmartTube REST API")
            indicator("Live", active: self.vm.isRealtimeConnected, help: "Realtime WebSocket")
            indicator("ADB", active: self.vm.isBridgeConnected, help: "ADB bridge")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous).fill(.quaternary.opacity(0.6))
        )
        .fixedSize()
    }

    private func indicator(_ title: String, active: Bool, help: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .help("\(help): \(active ? "connected" : "offline")")
    }
}

// MARK: - Queue sidebar

private struct QueueSidebar: View {
    @ObservedObject var vm: SmartTubeControllerViewModel

    private enum Feed: String, CaseIterable {
        case recommended = "Recommended"
        case related = "Related"
    }

    @AppStorage("smarttube.upnext.feed") private var feedRaw = Feed.recommended.rawValue
    private var feed: Feed { Feed(rawValue: self.feedRaw) ?? .recommended }

    var body: some View {
        List {
            // Up Next: toggle between Home recommendations and the current
            // video's related list. Both play by video ID on the backend.
            Section {
                Picker("Feed", selection: self.$feedRaw) {
                    ForEach(Feed.allCases, id: \.rawValue) { feed in
                        Text(feed.rawValue).tag(feed.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                let items = self.feed == .recommended ? self.vm.recommended : self.vm.suggestions
                if items.isEmpty {
                    Text(self.feed == .recommended ? "No recommendations yet" : "Play a video to see related")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            Task {
                                if self.feed == .recommended {
                                    await self.vm.playRecommended(item)
                                } else {
                                    await self.vm.playSuggestion(item, at: index)
                                }
                            }
                        } label: {
                            VideoRow(
                                item: item,
                                highlighted: item.videoId != nil && item.videoId == self.vm.player?.video?.videoId
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                if let id = item.videoId { Task { await self.vm.playNext(id) } }
                            }
                            Button("Add to Queue", systemImage: "plus") {
                                if let id = item.videoId { Task { await self.vm.addToQueue(id) } }
                            }
                        }
                    }
                }
            } header: {
                Text("Up Next")
            }

            if !self.vm.queue.isEmpty {
                Section("Queue") {
                    ForEach(self.vm.queue) { item in
                        VideoRow(item: item)
                            .contextMenu {
                                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                    if let id = item.videoId { Task { await self.vm.playNext(id) } }
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    Task { await self.vm.removeQueueItem(item) }
                                }
                            }
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    Task { await self.vm.removeQueueItem(item) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    Task {
                        await self.vm.refreshFast()
                        await self.vm.refreshSuggestions()
                        await self.vm.refreshRecommended()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh recommendations and queue")
                Button {
                    Task { await self.vm.clearQueue() }
                } label: {
                    Label("Clear Queue", systemImage: "trash")
                }
                .help("Clear the entire queue")
                .disabled(self.vm.queue.isEmpty)
            }
        }
    }
}

// Rich video row: thumbnail with duration badge, title, channel.
// `highlighted` overrides the server's is_current flag for lists that don't
// carry it (related/recommended), matching against the playing video instead.
private struct VideoRow: View {
    let item: QueueItem
    var highlighted: Bool?

    private var isNowPlaying: Bool { self.highlighted ?? (self.item.isCurrent == true) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let raw = self.item.thumbnailUrl, let url = URL(string: raw) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(Color(white: 0.15))
                            }
                        }
                    } else {
                        ZStack {
                            Rectangle().fill(Color(white: 0.15))
                            Image(systemName: "play.rectangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 92, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if self.item.isLive == true {
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.red, in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                } else if let ms = self.item.durationMs, ms > 0 {
                    Text(SmartTubeControllerViewModel.formatTime(ms))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                }

                if self.isNowPlaying {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: 92, height: 52)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if self.isNowPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(self.item.title ?? self.item.videoId ?? "Untitled")
                        .font(.callout.weight(self.isNowPlaying ? .semibold : .regular))
                        .lineLimit(2)
                }
                if let author = self.item.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(self.isNowPlaying ? 0.14 : 0))
        )
        .padding(.horizontal, -5)
    }
}

// MARK: - Now Playing (detail) — Liquid Glass media surface

private struct NowPlayingView: View {
    @ObservedObject var vm: SmartTubeControllerViewModel
    @State private var videoText = ""
    @State private var seekValue: Double = 0
    @State private var isDraggingSeek = false
    @State private var volume: Double = 0.8
    @State private var isDraggingVolume = false
    @State private var playerVolume: Double = 1.0
    @State private var isDraggingPlayerVolume = false
    @State private var subwooferLevel: Double = 8
    @State private var rearLevel: Double = 8
    @State private var immersiveAE = false
    @State private var soundMode: SmartTubeSoundMode = .cinema
    @State private var controlsExpanded = false
    @State private var titlebarHeight: CGFloat = 0
    @State private var searchDebounce: Task<Void, Never>?
    @Namespace private var controlsGlassNamespace

    private var isEmpty: Bool { self.videoText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 14) {
            self.stage
            self.playBar
        }
        .padding(16)
        // The split-view detail reports no top safe-area inset on macOS 26, so the
        // content would otherwise draw beneath the Liquid Glass toolbar. Measure the
        // titlebar+toolbar height from the window and pad the card down past it.
        .padding(.top, self.titlebarHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TitlebarHeightReader(height: self.$titlebarHeight))
        .onChange(of: self.vm.positionMs) { _, newValue in
            if !self.isDraggingSeek { self.seekValue = Double(newValue) }
        }
        .onChange(of: self.vm.theater?.volume) { _, newValue in
            if !self.isDraggingVolume, let tv = newValue { self.volume = Double(tv) / 100.0 }
        }
        .onChange(of: self.vm.player?.volume) { _, newValue in
            if !self.isDraggingPlayerVolume, let v = newValue { self.playerVolume = min(max(v, 0), 1) }
        }
        .onChange(of: self.vm.cec) { _, newValue in self.syncLevels(newValue) }
        .onAppear {
            self.volume = Double(self.vm.theater?.volume ?? 50) / 100.0
            self.syncLevels(self.vm.cec)
        }
    }

    private func syncLevels(_ cec: SmartTubeCECState?) {
        if let sub = cec?.subwooferLevel { self.subwooferLevel = Double(sub) }
        if let rear = cec?.rearLevel { self.rearLevel = Double(rear) }
        if let immersive = cec?.immersiveAEEnabled { self.immersiveAE = immersive }
        if let mode = cec?.soundMode { self.soundMode = mode }
    }

    // The artwork "stage": fills all available space, with glass controls floating on top.
    private var stage: some View {
        ZStack {
            self.artworkFill
            LinearGradient(
                colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )
            GeometryReader { proxy in
                let compact = proxy.size.height < 620 || proxy.size.width < 900
                VStack {
                    HStack(alignment: .top) {
                        Spacer()
                        self.topControlGroup(maxWidth: proxy.size.width - (compact ? 32 : 44))
                    }

                    Spacer(minLength: compact ? 12 : 24)

                    self.transportCluster
                        .scaleEffect(compact ? 0.86 : 1)

                    Spacer(minLength: compact ? 12 : 24)

                    VStack(spacing: compact ? 8 : 12) {
                        HStack(alignment: .bottom) {
                            self.titleOverlay
                            Spacer(minLength: 24)
                        }
                        .padding(.horizontal, compact ? 28 : 44)

                        self.scrubber
                            .padding(.horizontal, compact ? 22 : 30)
                            .padding(.vertical, compact ? 8 : 10)
                            .glassEffect(.clear.interactive().tint(.white.opacity(0.05)), in: .capsule)
                            .overlay {
                                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                            }
                            .padding(.horizontal, compact ? 18 : 28)

                    }
                    .padding(.bottom, compact ? 8 : 16)
                }
                .padding(compact ? 16 : 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var titleOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.vm.subtitle.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
            Text(self.vm.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .shadow(color: .black.opacity(0.85), radius: 8, y: 2)
    }

    private func topControlGroup(maxWidth: CGFloat) -> some View {
        let preferred: CGFloat = self.vm.playerVolumeEnabled ? 330 : 306
        let islandWidth = max(220, min(preferred, maxWidth))
        return GlassEffectContainer(spacing: 10) {
            if self.controlsExpanded {
                VStack(alignment: .trailing, spacing: 0) {
                    self.controlIslandHeader
                    VStack(spacing: 9) {
                        controlIslandRow(icon: "speaker.wave.3.fill", label: "TV") {
                            self.volumeCapsule
                        }
                        if self.vm.playerVolumeEnabled {
                            controlIslandRow(icon: "dial.medium", label: "Player") {
                                self.playerVolumeCapsule
                            }
                        }
                        controlIslandRow(icon: "hifispeaker.fill", label: "Subwoofer") {
                            levelCapsule(value: self.$subwooferLevel) { level in
                                await self.vm.setSubwoofer(level)
                            }
                        }
                        controlIslandRow(icon: "surround.sound", label: "Rear") {
                            levelCapsule(value: self.$rearLevel) { level in
                                await self.vm.setRear(level)
                            }
                        }
                        controlIslandRow(icon: "music.note", label: "Mode") {
                            self.soundModeCapsule
                        }
                        controlIslandRow(icon: "airpodspro", label: "Spatial") {
                            self.immersiveCapsule
                        }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 2)
                }
                .frame(width: islandWidth)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 11)
                .background {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.white.opacity(0.018))
                }
                .glassEffect(.clear.interactive().tint(.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .glassEffectID("controls-island", in: self.controlsGlassNamespace)
                .glassEffectTransition(.matchedGeometry)
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .trim(from: 0.04, to: 0.34)
                        .stroke(.white.opacity(0.26), lineWidth: 1)
                        .padding(2)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.30), radius: 16, y: 5)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                    removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing))
                ))
            } else {
                self.controlIslandButton
                    .glassEffectID("controls-island", in: self.controlsGlassNamespace)
                    .glassEffectTransition(.matchedGeometry)
            }
        }
        .glassEffectUnion(id: "controls-union", namespace: self.controlsGlassNamespace)
        .animation(.smooth(duration: 0.26), value: self.controlsExpanded)
    }

    private var controlIslandButton: some View {
        Button {
            self.toggleControlIsland()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(Int((self.volume * 100).rounded()))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 13, weight: .bold))
                    .opacity(0.72)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .homeTheaterGlassCapsule()
        .help("Expand playback controls")
    }

    private var controlIslandHeader: some View {
        Button {
            self.toggleControlIsland()
        } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(.white.opacity(0.42))
                    .frame(width: 28, height: 3)
                    .padding(.trailing, 3)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                Text("Audio Controls")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                Spacer(minLength: 10)
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 14, weight: .bold))
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Collapse playback controls")
    }

    private func controlIslandRow<Content: View>(
        icon: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.4)
            }
            .foregroundStyle(.white.opacity(0.62))
            .frame(width: 76, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }

    private func toggleControlIsland() {
        withAnimation(.smooth(duration: 0.24)) {
            self.controlsExpanded.toggle()
        }
    }

    private var artworkFill: some View {
        ZStack {
            Rectangle().fill(.black)
            if let hiRes = self.vm.hiResThumbnailURL {
                // Try maxres (1280×720) first; not all videos have it, so fall back
                // to the API-provided thumbnail on failure.
                AsyncImage(url: hiRes) { phase in
                    if let image = phase.image {
                        self.artworkLayers(image)
                    } else if case .failure = phase {
                        self.apiArtwork
                    } else {
                        self.apiArtwork
                    }
                }
            } else {
                self.apiArtwork
            }
        }
    }

    private var apiArtwork: some View {
        Group {
            if let url = self.vm.thumbnailURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        self.artworkLayers(image)
                    } else {
                        self.fallback
                    }
                }
            } else {
                self.fallback
            }
        }
    }

    private func artworkLayers(_ image: Image) -> some View {
        ZStack {
            image.resizable().scaledToFill().blur(radius: 44).opacity(0.55)
            image.resizable().scaledToFit()
        }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "play.tv")
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.25))
        }
    }

    // Draggable TV / audio-system volume bar (top-right capsule). Drives the TV's
    // actual volume, not the player's internal gain — internal volume is something
    // SmartTube re-applies per video and isn't what a remote should control.
    private var volumeCapsule: some View {
        HStack(spacing: 12) {
            Button {
                Task { await self.vm.toggleTVMute() }
            } label: {
                Image(systemName: self.vm.theater?.muted == true ? "speaker.slash.fill"
                      : self.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(self.vm.theater?.muted == true ? "Unmute TV" : "Mute TV")
            GlassTrack(
                progress: self.volume,
                onScrub: { fraction in
                    self.isDraggingVolume = true
                    self.volume = fraction
                },
                onCommit: { fraction in
                    self.volume = fraction
                    self.isDraggingVolume = false
                    Task { await self.vm.setTVVolume(percent: Int((fraction * 100).rounded())) }
                }
            )
            .frame(maxWidth: .infinity)
            Text("\(Int((self.volume * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 24, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .homeTheaterGlassCapsule()
        .help("TV volume")
    }

    // Optional secondary control: ExoPlayer's internal volume (pre-amp gain).
    // Off by default; enabled via Settings → "Player volume as secondary control".
    private var playerVolumeCapsule: some View {
        HStack(spacing: 12) {
            GlassTrack(
                progress: self.playerVolume,
                onScrub: { fraction in
                    self.isDraggingPlayerVolume = true
                    self.playerVolume = fraction
                },
                onCommit: { fraction in
                    self.playerVolume = fraction
                    self.isDraggingPlayerVolume = false
                    Task { await self.vm.setPlaybackVolume(percent: Int((fraction * 100).rounded())) }
                }
            )
            .frame(maxWidth: .infinity)
            Text("\(Int((self.playerVolume * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 24, alignment: .trailing)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .homeTheaterGlassCapsule()
        .help("Player volume (internal pre-amp gain)")
    }

    private var soundModeCapsule: some View {
        Menu {
            ForEach(SmartTubeSoundMode.allCases, id: \.self) { mode in
                Button(mode.rawValue.capitalized) {
                    self.soundMode = mode
                    Task { await self.vm.setSoundMode(mode) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(self.soundMode.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .homeTheaterGlassCapsule()
    }

    private var immersiveCapsule: some View {
        Button {
            let next = !self.immersiveAE
            self.immersiveAE = next
            Task { await self.vm.setImmersive(next) }
        } label: {
            self.miniSwitch(on: self.immersiveAE)
        }
        .buttonStyle(.plain)
        .help(self.immersiveAE ? "Spatial audio on" : "Spatial audio off")
    }

    // A compact iOS-style on/off switch, sized to sit on the right of a control row.
    private func miniSwitch(on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Color.accentColor : Color.white.opacity(0.18))
                .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                .frame(width: 42, height: 25)
            Circle()
                .fill(.white)
                .frame(width: 19, height: 19)
                .padding(3)
                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
        }
        .animation(.smooth(duration: 0.2), value: on)
    }

    private func levelCapsule(value: Binding<Double>, action: @escaping (Double) async -> Void) -> some View {
        HStack(spacing: 12) {
            GlassTrack(
                progress: value.wrappedValue / 12.0,
                onScrub: { fraction in value.wrappedValue = (fraction * 12).rounded() },
                onCommit: { fraction in
                    let level = (fraction * 12).rounded()
                    value.wrappedValue = level
                    Task { await action(level) }
                }
            )
            .frame(maxWidth: .infinity)
            Text("\(Int(value.wrappedValue))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .homeTheaterGlassCapsule()
    }

    private var transportCluster: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                glassButton("backward.end.fill", size: .secondary, help: "Previous") { await self.vm.previous() }
                glassButton("gobackward.10", size: .primary, help: "Back 10 seconds") { await self.vm.seekBy(seconds: -10) }
                Button {
                    Task { await self.vm.togglePlay() }
                } label: {
                    if self.vm.isBuffering {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                    } else {
                        Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .buttonStyle(PlayerGlassButtonStyle(size: .play))
                .help(self.vm.isBuffering ? "Buffering" : self.vm.isPlaying ? "Pause" : "Play")
                glassButton("goforward.10", size: .primary, help: "Forward 10 seconds") { await self.vm.seekBy(seconds: 10) }
                glassButton("forward.end.fill", size: .secondary, help: "Next") { await self.vm.next() }
            }
            .controlSize(.large)
        }
    }

    private func glassButton(
        _ symbol: String,
        size: PlayerGlassButtonSize,
        help: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(PlayerGlassButtonStyle(size: size))
        .help(help)
    }

    private var scrubber: some View {
        let duration = Double(max(self.vm.durationMs, 1))
        return HStack(spacing: 12) {
            Text(SmartTubeControllerViewModel.formatTime(Int(self.seekValue)))
                .foregroundStyle(.white.opacity(0.7))
            GlassTrack(
                progress: self.seekValue / duration,
                onScrub: { fraction in
                    self.isDraggingSeek = true
                    self.seekValue = fraction * duration
                },
                onCommit: { fraction in
                    self.seekValue = fraction * duration
                    self.isDraggingSeek = false
                    Task { await self.vm.seek(ms: Int(self.seekValue)) }
                }
            )
            Text("−" + SmartTubeControllerViewModel.formatTime(max(self.vm.durationMs - Int(self.seekValue), 0)))
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.caption.monospacedDigit())
    }

    // Single smart field: a URL/ID plays directly; anything else searches as you
    // type and shows a results picker floating above the bar.
    private var playBar: some View {
        HStack(spacing: 10) {
            Image(systemName: self.vm.isSearching ? "magnifyingglass" : "play.circle")
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
            TextField("Play a YouTube URL, video ID, or search…", text: self.$videoText)
                .textFieldStyle(.plain)
                .onSubmit { self.submit() }
            if !self.isEmpty {
                Button {
                    self.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                Button("Play") { self.submit() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                Menu {
                    Button("Add to Queue") { self.queue(next: false) }
                    Button("Play Next") { self.queue(next: true) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Queue options")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .overlay(alignment: .top) {
            if self.searchPanelVisible {
                self.searchResultsPanel
                    // Anchor the panel's bottom edge just above the bar's top edge,
                    // so it floats over the stage without disturbing layout.
                    .alignmentGuide(.top) { dimensions in dimensions[.bottom] + 10 }
            }
        }
        .onChange(of: self.videoText) { _, text in self.scheduleSearch(text) }
        .onExitCommand { self.clearSearch() }
        .animation(.smooth(duration: 0.2), value: self.searchPanelVisible)
    }

    private var searchPanelVisible: Bool {
        !self.isEmpty && (self.vm.isSearching || !self.vm.searchResults.isEmpty)
    }

    private var searchResultsPanel: some View {
        Group {
            if self.vm.searchResults.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(self.vm.searchResults) { item in
                            SearchResultRow(item: item) {
                                self.playResult(item)
                            } queueAction: { next in
                                guard let id = item.videoId else { return }
                                Task { next ? await self.vm.playNext(id) : await self.vm.addToQueue(id) }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(self.vm.searchResults.count) * 52 + 12, 312))
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func playResult(_ item: QueueItem) {
        guard let id = item.videoId else { return }
        self.clearSearch()
        Task { await self.vm.playVideoId(id) }
    }

    private func clearSearch() {
        self.searchDebounce?.cancel()
        self.videoText = ""
        self.vm.clearSearchResults()
    }

    private func scheduleSearch(_ text: String) {
        self.searchDebounce?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !Self.looksLikeVideo(trimmed) else {
            self.vm.clearSearchResults()
            return
        }
        self.searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self.vm.search(trimmed)
        }
    }

    private func submit() {
        let v = self.videoText.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        // Prefer the first concrete search result over the server's blind
        // search-and-play, so Enter plays exactly what the picker shows.
        let firstResult = self.vm.searchResults.first?.videoId
        self.clearSearch()
        Task {
            if Self.looksLikeVideo(v) {
                await self.vm.openVideo(v)
            } else if let id = firstResult {
                await self.vm.playVideoId(id)
            } else {
                await self.vm.searchAndPlay(v)
            }
        }
    }

    private func queue(next: Bool) {
        let v = self.videoText.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        self.videoText = ""
        Task { next ? await self.vm.playNext(v) : await self.vm.addToQueue(v) }
    }

    private static func looksLikeVideo(_ text: String) -> Bool {
        if text.contains("youtube.com") || text.contains("youtu.be") || text.contains("/") { return true }
        return text.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

// One row in the search-results picker: thumbnail, title/channel, duration.
// Click plays; right-click (or the hover ellipsis) queues.
private struct SearchResultRow: View {
    let item: QueueItem
    let playAction: () -> Void
    let queueAction: (_ next: Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: self.playAction) {
            HStack(spacing: 10) {
                AsyncImage(url: self.item.thumbnailUrl.flatMap(URL.init)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 71, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.item.title ?? "Untitled")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(self.item.author ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if self.hovering {
                    Menu {
                        Button("Add to Queue") { self.queueAction(false) }
                        Button("Play Next") { self.queueAction(true) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else if self.item.isLive == true {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                } else if let ms = self.item.durationMs, ms > 0 {
                    Text(SmartTubeControllerViewModel.formatTime(ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.primary.opacity(self.hovering ? 0.08 : 0))
        )
        .onHover { self.hovering = $0 }
        .contextMenu {
            Button("Add to Queue") { self.queueAction(false) }
            Button("Play Next") { self.queueAction(true) }
        }
    }
}

private enum PlayerGlassButtonSize {
    case secondary
    case primary
    case play

    var diameter: CGFloat {
        switch self {
        case .secondary: 48
        case .primary: 62
        case .play: 88
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .secondary: 17
        case .primary: 23
        case .play: 36
        }
    }

    var iconWeight: Font.Weight {
        switch self {
        case .secondary: .semibold
        case .primary, .play: .bold
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .secondary: 8
        case .primary: 11
        case .play: 15
        }
    }

    var fillOpacity: Double {
        switch self {
        case .secondary: 0.05
        case .primary: 0.08
        case .play: 0.10
        }
    }

    var glassTintOpacity: Double {
        switch self {
        case .secondary: 0.02
        case .primary: 0.045
        case .play: 0.065
        }
    }
}

private struct PlayerGlassButtonStyle: ButtonStyle {
    let size: PlayerGlassButtonSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: self.size.iconSize, weight: self.size.iconWeight))
            .foregroundStyle(.white)
            .frame(width: self.size.diameter, height: self.size.diameter)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? self.size.fillOpacity + 0.05 : self.size.fillOpacity))
            }
            .glassEffect(.clear.interactive().tint(.white.opacity(configuration.isPressed ? self.size.glassTintOpacity + 0.05 : self.size.glassTintOpacity)), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.62 : 0.38), lineWidth: 1.1)
            }
            .overlay(alignment: .top) {
                Circle()
                    .trim(from: 0.07, to: 0.43)
                    .stroke(.white.opacity(configuration.isPressed ? 0.18 : 0.42), lineWidth: 1.35)
                    .frame(width: self.size.diameter - 6, height: self.size.diameter - 6)
                    .blur(radius: 0.25)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .trim(from: 0.56, to: 0.80)
                    .stroke(.black.opacity(configuration.isPressed ? 0.06 : 0.16), lineWidth: 1.2)
                    .frame(width: self.size.diameter - 5, height: self.size.diameter - 5)
                    .blur(radius: 0.35)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.38), radius: self.size.shadowRadius, y: self.size.shadowRadius * 0.24)
            .shadow(color: .white.opacity(0.16), radius: 1.5, y: -0.8)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}

// Reports the window's titlebar+toolbar height (frame minus contentLayoutRect).
// The split-view detail gets no top safe-area inset on macOS 26, so views that
// shouldn't sit under the glass toolbar pad themselves down by this amount.
private struct TitlebarHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.report(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { self.report(view) }
    }

    private func report(_ view: NSView) {
        guard let window = view.window else { return }
        let measured = window.frame.height - window.contentLayoutRect.height
        if abs(measured - self.height) > 0.5 {
            self.height = measured
        }
    }
}

private struct HomeTheaterGlassCapsule: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(.white.opacity(0.035))
            }
            .glassEffect(.clear.interactive().tint(self.tint ?? .white.opacity(0.025)), in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .trim(from: 0.06, to: 0.42)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
                    .padding(2)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.24), radius: 7, y: 2)
    }
}

private extension View {
    func homeTheaterGlassCapsule(tint: Color? = nil) -> some View {
        self.modifier(HomeTheaterGlassCapsule(tint: tint))
    }
}

// A thick, draggable capsule track used for the scrubber and the volume bar.
// Reports the drag fraction live (onScrub) and on release (onCommit).
private struct GlassTrack: View {
    var progress: Double
    var onScrub: (Double) -> Void
    var onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(self.progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule().fill(.white).frame(width: geo.size.width * clamped)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        self.onScrub(min(max(value.location.x / geo.size.width, 0), 1))
                    }
                    .onEnded { value in
                        self.onCommit(min(max(value.location.x / geo.size.width, 0), 1))
                    }
            )
        }
        .frame(height: 6)
    }
}

// MARK: - Playback inspector

private struct PlaybackInspector: View {
    @ObservedObject var vm: SmartTubeControllerViewModel

    var body: some View {
        Form {
            Section("Tracks") {
                formatPicker("Quality", systemImage: "4k.tv", formats: self.vm.videoFormats) { id in
                    Task { await self.vm.setVideoFormat(id) }
                }
                formatPicker("Audio", systemImage: "waveform", formats: self.vm.audioFormats) { id in
                    Task { await self.vm.setAudioFormat(id) }
                }
                subtitlePicker
            }

            Section("Home Theater") {
                Picker(selection: speakerBinding) {
                    Text("Home Theater").tag(true)
                    Text("TV Speakers").tag(false)
                } label: {
                    Label("Output", systemImage: "hifispeaker.2")
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await self.vm.powerToggle() }
                } label: {
                    Label("Power Toggle", systemImage: "power")
                }
            }

            Section {
                LabeledContent("TV Volume", value: "\(self.vm.theater?.volume ?? 0)")
                LabeledContent("Queue", value: "\(self.vm.queue.count) items")
                LabeledContent("Audio Output", value: self.vm.theater?.audioOutput ?? "Unknown")
            } header: {
                Text("Status")
            } footer: {
                if let error = self.vm.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var subtitlePicker: some View {
        Picker(selection: subtitleBinding) {
            Text("Off").tag(Optional<String>.none)
            ForEach(self.vm.subtitleFormats) { format in
                Text(format.title).tag(Optional(format.id))
            }
        } label: {
            Label("Subtitles", systemImage: "captions.bubble")
        }
        .disabled(self.vm.subtitleFormats.isEmpty)
    }

    private var subtitleBinding: Binding<String?> {
        Binding(
            get: { self.vm.subtitleFormats.first(where: { $0.selected })?.id },
            set: { id in Task { await self.vm.setSubtitleFormat(id) } }
        )
    }

    private var speakerBinding: Binding<Bool> {
        Binding(
            get: { (self.vm.theater?.audioOutput ?? "").lowercased().contains("theater") },
            set: { isTheater in
                Task {
                    if isTheater { await self.vm.setHomeTheater() } else { await self.vm.setTVSpeakers() }
                }
            }
        )
    }

    private func formatPicker(_ title: String, systemImage: String, formats: [RemoteFormat], action: @escaping (String) -> Void) -> some View {
        Picker(selection: Binding(
            get: { formats.first(where: { $0.selected })?.id ?? "" },
            set: { id in if !id.isEmpty { action(id) } }
        )) {
            if formats.isEmpty {
                Text("No data").tag("")
            } else if formats.first(where: { $0.selected }) == nil {
                Text("Auto").tag("")
            }
            ForEach(formats) { format in
                Text(format.subtitle.isEmpty ? format.title : "\(format.title) · \(format.subtitle)")
                    .tag(format.id)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(formats.isEmpty)
    }

}

// MARK: - Connection settings sheet

private struct ConnectionSettingsSheet: View {
    @ObservedObject var vm: SmartTubeControllerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("SmartTube API") {
                    TextField("Host", text: self.$vm.host)
                    TextField("Port", text: self.$vm.apiPort)
                    LabeledContent("Token", value: self.vm.redactedToken)
                }
                Section {
                    TextField("TV IP (blank = same as API host)", text: self.$vm.bridgeHost)
                    TextField("ADB Port", text: self.$vm.bridgePort)
                    Button("Reconnect ADB") {
                        Task { await self.vm.connectBridgeIfPossible() }
                    }
                    Text(self.vm.bridgePhase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("ADB (Home Theater)")
                } footer: {
                    Text("Runs adb directly to control the TV's home-theater (subwoofer, rear, sound mode) over the network on port 5555.")
                        .font(.caption)
                }
                Section {
                    Toggle("Player volume as secondary control", isOn: self.$vm.playerVolumeEnabled)
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Shows a second slider for the player's internal volume (pre-amp gain). TV volume remains the primary control.")
                        .font(.caption)
                }
                Section {
                    Button("Connect & Pair") {
                        Task { await self.vm.manualConnect() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { self.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 460)
    }
}

// MARK: - Activity log sheet

private struct ActivityLogSheet: View {
    @ObservedObject var vm: SmartTubeControllerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity Log")
                    .font(.headline)
                Spacer()
                Button("Copy") { self.vm.copyLogs() }
                Button("Done") { self.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(self.vm.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 560, height: 460)
    }
}

#Preview {
    ContentView()
}
