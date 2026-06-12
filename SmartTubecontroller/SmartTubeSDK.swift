// SmartTubeSDK.swift
// Single-file Swift wrapper for the SmartTube Remote Control API.
// Supports: pairing, REST commands, WebSocket state updates, UDP discovery, and HTTP subnet scanning.
// Platforms: iOS 15+, macOS 12+, tvOS 15+ where APIs/network entitlements permit.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Core Config

public struct SmartTubeConfig: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var token: String?

    public init(host: String, port: Int = 8497, token: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    public var webSocketURL: URL? {
        guard let token else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }
}

// MARK: - Errors

public enum SmartTubeError: Error, LocalizedError, Sendable {
    case missingToken
    case invalidURL
    case emptyResponse
    case invalidResponse
    case httpStatus(Int, String?)
    case apiError(code: Int, message: String)
    case decoding(Error, raw: String?)
    case encoding(Error)
    case socketUnsupported
    case socketFailed(String)
    case websocketNotConnected

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Missing SmartTube auth token. Pair first or pass a token."
        case .invalidURL:
            return "Invalid SmartTube URL."
        case .emptyResponse:
            return "Empty response from SmartTube."
        case .invalidResponse:
            return "Invalid HTTP response from SmartTube."
        case .httpStatus(let code, let body):
            return "HTTP \(code)\(body.map { ": \($0)" } ?? "")"
        case .apiError(let code, let message):
            return "SmartTube API error \(code): \(message)"
        case .decoding(let error, let raw):
            return "Failed to decode response: \(error.localizedDescription)\(raw.map { " Raw: \($0)" } ?? "")"
        case .encoding(let error):
            return "Failed to encode request: \(error.localizedDescription)"
        case .socketUnsupported:
            return "UDP discovery uses POSIX sockets and is only implemented on Darwin platforms in this file."
        case .socketFailed(let message):
            return "Socket error: \(message)"
        case .websocketNotConnected:
            return "WebSocket is not connected."
        }
    }
}

// MARK: - API Error Envelope

public struct SmartTubeAPIErrorEnvelope: Decodable, Sendable {
    public let error: SmartTubeAPIError
}

public struct SmartTubeAPIError: Decodable, Sendable {
    public let code: Int
    public let message: String
}

// MARK: - Generic JSON Value

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Common Models

public struct EmptyBody: Encodable, Sendable {
    public init() {}
}

public struct OKResponse: Codable, Sendable, Equatable {
    public let ok: Bool
}

public struct PingResponse: Codable, Sendable, Equatable {
    public let status: String
    public let deviceName: String
    public let appVersion: String
    public let apiVersion: String
    /// Absent on older servers → treat as paired (true).
    public let pairingRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case deviceName = "device_name"
        case appVersion = "app_version"
        case apiVersion = "api_version"
        case pairingRequired = "pairing_required"
    }
}

public struct PairCodeResponse: Codable, Sendable, Equatable {
    public let code: String
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case code
        case expiresIn = "expires_in"
    }
}

public struct PairVerifyResponse: Codable, Sendable, Equatable {
    public let token: String
    public let deviceName: String

    enum CodingKeys: String, CodingKey {
        case token
        case deviceName = "device_name"
    }
}

public struct DiscoveryDevice: Codable, Sendable, Hashable {
    public var host: String?
    public let deviceName: String
    public let deviceId: String
    public let apiPort: Int
    public let appVersion: String
    public let apiVersion: String

    public init(
        host: String? = nil,
        deviceName: String,
        deviceId: String,
        apiPort: Int,
        appVersion: String,
        apiVersion: String
    ) {
        self.host = host
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.apiPort = apiPort
        self.appVersion = appVersion
        self.apiVersion = apiVersion
    }

    enum CodingKeys: String, CodingKey {
        case host
        case deviceName = "device_name"
        case deviceId = "device_id"
        case apiPort = "api_port"
        case appVersion = "app_version"
        case apiVersion = "api_version"
    }
}

public enum PlayerStateValue: String, Codable, Sendable, Equatable {
    case playing
    case paused
    case buffering
    case idle
    case ended

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? "idle"
        self = PlayerStateValue(rawValue: raw) ?? .idle
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PlayerState: Codable, Sendable, Equatable {
    public let state: PlayerStateValue
    public let video: VideoInfo?
    public let positionMs: Int?
    public let durationMs: Int?
    public let speed: Double?
    public let pitch: Double?
    public let volume: Double?
    public let selectedTracks: SelectedTracks?
    public let videoTransform: VideoTransform?
    public let suggestionsCount: Int?
    public let queueSize: Int?
    public let queueIndex: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case video
        case positionMs = "position_ms"
        case durationMs = "duration_ms"
        case speed
        case pitch
        case volume
        case selectedTracks = "selected_tracks"
        case videoTransform = "video_transform"
        case suggestionsCount = "suggestions_count"
        case queueSize = "queue_size"
        case queueIndex = "queue_index"
    }

    public init(
        state: PlayerStateValue = .idle,
        video: VideoInfo? = nil,
        positionMs: Int? = nil,
        durationMs: Int? = nil,
        speed: Double? = nil,
        pitch: Double? = nil,
        volume: Double? = nil,
        selectedTracks: SelectedTracks? = nil,
        videoTransform: VideoTransform? = nil,
        suggestionsCount: Int? = nil,
        queueSize: Int? = nil,
        queueIndex: Int? = nil
    ) {
        self.state = state
        self.video = video
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.speed = speed
        self.pitch = pitch
        self.volume = volume
        self.selectedTracks = selectedTracks
        self.videoTransform = videoTransform
        self.suggestionsCount = suggestionsCount
        self.queueSize = queueSize
        self.queueIndex = queueIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = (try? c.decodeIfPresent(PlayerStateValue.self, forKey: .state)) ?? .idle
        self.video = (try? c.decodeIfPresent(VideoInfo.self, forKey: .video)) ?? nil
        self.positionMs = (try? c.decodeIfPresent(Int.self, forKey: .positionMs)) ?? nil
        self.durationMs = (try? c.decodeIfPresent(Int.self, forKey: .durationMs)) ?? nil
        self.speed = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? nil
        self.pitch = (try? c.decodeIfPresent(Double.self, forKey: .pitch)) ?? nil
        self.volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? nil
        self.selectedTracks = (try? c.decodeIfPresent(SelectedTracks.self, forKey: .selectedTracks)) ?? nil
        self.videoTransform = (try? c.decodeIfPresent(VideoTransform.self, forKey: .videoTransform)) ?? nil
        self.suggestionsCount = (try? c.decodeIfPresent(Int.self, forKey: .suggestionsCount)) ?? nil
        self.queueSize = (try? c.decodeIfPresent(Int.self, forKey: .queueSize)) ?? nil
        self.queueIndex = (try? c.decodeIfPresent(Int.self, forKey: .queueIndex)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(video, forKey: .video)
        try c.encodeIfPresent(positionMs, forKey: .positionMs)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encodeIfPresent(speed, forKey: .speed)
        try c.encodeIfPresent(pitch, forKey: .pitch)
        try c.encodeIfPresent(volume, forKey: .volume)
        try c.encodeIfPresent(selectedTracks, forKey: .selectedTracks)
        try c.encodeIfPresent(videoTransform, forKey: .videoTransform)
        try c.encodeIfPresent(suggestionsCount, forKey: .suggestionsCount)
        try c.encodeIfPresent(queueSize, forKey: .queueSize)
        try c.encodeIfPresent(queueIndex, forKey: .queueIndex)
    }
}

public struct VideoInfo: Codable, Sendable, Equatable {
    public let videoId: String?
    public let title: String?
    public let author: String?
    public let channelId: String?
    public let thumbnailURL: String?
    public let durationMs: Int?
    public let isLive: Bool?
    public let isShorts: Bool?
    public let playlistId: String?
    public let playlistIndex: Int?

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case title
        case author
        case channelId = "channel_id"
        case thumbnailURL = "thumbnail_url"
        case durationMs = "duration_ms"
        case isLive = "is_live"
        case isShorts = "is_shorts"
        case playlistId = "playlist_id"
        case playlistIndex = "playlist_index"
    }
}

public struct SelectedTracks: Codable, Sendable, Equatable {
    public let video: VideoFormat?
    public let audio: AudioFormat?
    public let subtitle: SubtitleFormat?
}

public struct VideoFormat: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if !formatId.isEmpty { return formatId }
        return "video-\(label ?? "")-\(width ?? -999)-\(height ?? -999)-\(codec ?? "")-\(bitrate ?? -1)"
    }

    public let formatId: String
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let codec: String?
    public let bitrate: Int?
    public let label: String?
    public let language: String?
    public let isSelected: Bool?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case width
        case height
        case frameRate = "frame_rate"
        case codec
        case bitrate
        case label
        case language
        case isSelected = "is_selected"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatId = (try? c.decode(String.self, forKey: .formatId)) ?? ""
        self.width = Self.decodeInt(c, .width)
        self.height = Self.decodeInt(c, .height)
        self.frameRate = Self.decodeDouble(c, .frameRate)
        self.codec = try? c.decode(String.self, forKey: .codec)
        self.bitrate = Self.decodeInt(c, .bitrate)
        self.label = try? c.decode(String.self, forKey: .label)
        self.language = try? c.decode(String.self, forKey: .language)
        self.isSelected = try? c.decode(Bool.self, forKey: .isSelected)
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: key) { return v }
        if let v = try? c.decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Int(v) }
        return nil
    }

    private static func decodeDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let v = try? c.decode(Double.self, forKey: key) { return v }
        if let v = try? c.decode(Int.self, forKey: key) { return Double(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Double(v) }
        return nil
    }
}

public struct AudioFormat: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if !formatId.isEmpty { return formatId }
        return "audio-\(label ?? "")-\(codec ?? "")-\(bitrate ?? -1)-\(language ?? "")"
    }

    public let formatId: String
    public let codec: String?
    public let language: String?
    public let languageLabel: String?
    public let bitrate: Int?
    public let label: String?
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let isSelected: Bool?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case codec
        case language
        case languageLabel = "language_label"
        case bitrate
        case label
        case width
        case height
        case frameRate = "frame_rate"
        case isSelected = "is_selected"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatId = (try? c.decode(String.self, forKey: .formatId)) ?? ""
        self.codec = try? c.decode(String.self, forKey: .codec)
        self.language = try? c.decode(String.self, forKey: .language)
        self.languageLabel = try? c.decode(String.self, forKey: .languageLabel)
        self.bitrate = Self.decodeInt(c, .bitrate)
        self.label = try? c.decode(String.self, forKey: .label)
        self.width = Self.decodeInt(c, .width)
        self.height = Self.decodeInt(c, .height)
        self.frameRate = Self.decodeDouble(c, .frameRate)
        self.isSelected = try? c.decode(Bool.self, forKey: .isSelected)
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: key) { return v }
        if let v = try? c.decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Int(v) }
        return nil
    }

    private static func decodeDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let v = try? c.decode(Double.self, forKey: key) { return v }
        if let v = try? c.decode(Int.self, forKey: key) { return Double(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Double(v) }
        return nil
    }
}

public struct SubtitleFormat: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if !formatId.isEmpty { return "\(formatId)-\(label ?? language ?? languageLabel ?? "")" }
        return "subtitle-\(label ?? "")-\(language ?? "")"
    }

    public let formatId: String
    public let language: String?
    public let languageLabel: String?
    public let label: String?
    public let codec: String?
    public let bitrate: Int?
    public let isSelected: Bool?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case language
        case languageLabel = "language_label"
        case label
        case codec
        case bitrate
        case isSelected = "is_selected"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatId = (try? c.decode(String.self, forKey: .formatId)) ?? ""
        self.language = try? c.decode(String.self, forKey: .language)
        self.languageLabel = try? c.decode(String.self, forKey: .languageLabel)
        self.label = try? c.decode(String.self, forKey: .label)
        self.codec = try? c.decode(String.self, forKey: .codec)
        self.bitrate = Self.decodeInt(c, .bitrate)
        self.isSelected = try? c.decode(Bool.self, forKey: .isSelected)
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: key) { return v }
        if let v = try? c.decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Int(v) }
        return nil
    }
}

public struct VideoTransform: Codable, Sendable, Equatable {
    public let resizeMode: Int?
    public let zoomPercents: Int?
    public let rotationAngle: Int?
    public let flipEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case resizeMode = "resize_mode"
        case zoomPercents = "zoom_percents"
        case rotationAngle = "rotation_angle"
        case flipEnabled = "flip_enabled"
    }
}

public struct SeekResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let positionMs: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case positionMs = "position_ms"
    }
}

public struct SpeedState: Codable, Sendable, Equatable {
    public let speed: Double
}

public struct PitchState: Codable, Sendable, Equatable {
    public let pitch: Double
}

public struct PlaybackVolumeState: Codable, Sendable, Equatable {
    public let volume: Double
    public let muted: Bool?
}

public struct MuteState: Codable, Sendable, Equatable {
    public let muted: Bool
}

public struct SubtitleState: Codable, Sendable, Equatable {
    public let enabled: Bool?
    public let subtitle: SubtitleFormat?
}

public struct SelectedTracksResponse: Codable, Sendable, Equatable {
    public let video: VideoFormat?
    public let audio: AudioFormat?
    public let subtitle: SubtitleFormat?
}

public struct ResizeState: Codable, Sendable, Equatable {
    public let mode: Int?
    public let resizeMode: Int?

    enum CodingKeys: String, CodingKey {
        case mode
        case resizeMode = "resize_mode"
    }
}

public struct ZoomState: Codable, Sendable, Equatable {
    public let zoom: Int?
    public let zoomPercents: Int?

    enum CodingKeys: String, CodingKey {
        case zoom
        case zoomPercents = "zoom_percents"
    }
}

public struct RotationState: Codable, Sendable, Equatable {
    public let angle: Int?
    public let rotationAngle: Int?

    enum CodingKeys: String, CodingKey {
        case angle
        case rotationAngle = "rotation_angle"
    }
}

public struct FlipState: Codable, Sendable, Equatable {
    public let enabled: Bool?
    public let flipEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled
        case flipEnabled = "flip_enabled"
    }
}

public struct QueueItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(index ?? -1)-\(videoId ?? UUID().uuidString)" }
    public let index: Int?
    public let videoId: String?
    public let title: String?
    public let author: String?
    public let isCurrent: Bool?
    public let thumbnailUrl: String?
    public let durationMs: Int?
    public let isLive: Bool?

    enum CodingKeys: String, CodingKey {
        case index
        case videoId = "video_id"
        case title
        case author
        case isCurrent = "is_current"
        case thumbnailUrl = "thumbnail_url"
        case durationMs = "duration_ms"
        case isLive = "is_live"
    }
}

public typealias SuggestionItem = QueueItem

public struct TheaterState: Codable, Sendable, Equatable {
    public let volume: Int
    public let muted: Bool
    public let audioOutput: String?

    enum CodingKeys: String, CodingKey {
        case volume
        case muted
        case audioOutput = "audio_output"
    }

    public init(volume: Int = 0, muted: Bool = false, audioOutput: String? = nil) {
        self.volume = volume
        self.muted = muted
        self.audioOutput = audioOutput
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.volume = (try? c.decodeIfPresent(Int.self, forKey: .volume)) ?? 0
        self.muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        self.audioOutput = (try? c.decodeIfPresent(String.self, forKey: .audioOutput)) ?? nil
    }
}

public struct TheaterVolumeState: Codable, Sendable, Equatable {
    public let volume: Int
    public let muted: Bool
}

public enum DPadKey: String, Codable, Sendable {
    case up
    case down
    case left
    case right
    case enter
    case back
}

public enum VoiceAction: String, Codable, Sendable {
    case start
}

public enum SoundMode: String, Codable, Sendable {
    case auto
    case cinema
    case music
    case standard
}

// MARK: - Request Bodies

private struct PairVerifyBody: Encodable, Sendable {
    let code: String
}

private struct SeekBody: Encodable, Sendable {
    let position_ms: Int
}

private struct SpeedBody: Encodable, Sendable {
    let speed: Double
}

private struct VolumeBody: Encodable, Sendable {
    let volume: Double
}

private struct TheaterVolumeBody: Encodable, Sendable {
    let volume: Int
}

private struct PitchBody: Encodable, Sendable {
    let pitch: Double
}

private struct FormatIdBody: Encodable, Sendable {
    let formatId: String?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let formatId {
            try container.encode(formatId, forKey: .formatId)
        } else {
            try container.encodeNil(forKey: .formatId)
        }
    }
}

private struct ResizeBody: Encodable, Sendable {
    let mode: Int
}

private struct ZoomBody: Encodable, Sendable {
    let zoom: Int
}

private struct RotationBody: Encodable, Sendable {
    let angle: Int
}

private struct FlipBody: Encodable, Sendable {
    let enabled: Bool
}

public struct OpenContentRequest: Encodable, Sendable, Equatable {
    public let url: String?
    public let videoId: String?
    public let positionMs: Int?
    public let playlistId: String?
    public let playlistIndex: Int?

    public init(
        url: String? = nil,
        videoId: String? = nil,
        positionMs: Int? = nil,
        playlistId: String? = nil,
        playlistIndex: Int? = nil
    ) {
        self.url = url
        self.videoId = videoId
        self.positionMs = positionMs
        self.playlistId = playlistId
        self.playlistIndex = playlistIndex
    }

    public static func url(_ url: String, positionMs: Int? = nil) -> OpenContentRequest {
        OpenContentRequest(url: url, positionMs: positionMs)
    }

    public static func videoId(_ videoId: String, positionMs: Int? = nil) -> OpenContentRequest {
        OpenContentRequest(videoId: videoId, positionMs: positionMs)
    }

    public static func playlist(videoId: String, playlistId: String, playlistIndex: Int) -> OpenContentRequest {
        OpenContentRequest(videoId: videoId, playlistId: playlistId, playlistIndex: playlistIndex)
    }

    enum CodingKeys: String, CodingKey {
        case url
        case videoId = "video_id"
        case positionMs = "position_ms"
        case playlistId = "playlist_id"
        case playlistIndex = "playlist_index"
    }
}

private struct SearchBody: Encodable, Sendable {
    let query: String
}

private struct QueueVideoBody: Encodable, Sendable {
    let video_id: String
}

private struct VoiceBody: Encodable, Sendable {
    let action: VoiceAction
}

// MARK: - REST Client

public actor SmartTubeClient {
    public private(set) var config: SmartTubeConfig

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(config: SmartTubeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func updateToken(_ token: String?) {
        config.token = token
    }

    public func updateHost(_ host: String, port: Int? = nil) {
        config.host = host
        if let port { config.port = port }
    }

    // MARK: System / Pairing

    public func ping() async throws -> PingResponse {
        try await request("GET", "/api/system/ping", auth: false, response: PingResponse.self)
    }

    public func getPairCode() async throws -> PairCodeResponse {
        try await request("GET", "/api/pair", auth: false, response: PairCodeResponse.self)
    }

    @discardableResult
    public func verifyPairCode(_ code: String, storeToken: Bool = true) async throws -> PairVerifyResponse {
        let result = try await request(
            "POST",
            "/api/pair/verify",
            auth: false,
            body: PairVerifyBody(code: code),
            response: PairVerifyResponse.self
        )
        if storeToken { config.token = result.token }
        return result
    }

    public static func ping(host: String, port: Int = 8497, session: URLSession = .shared) async throws -> PingResponse {
        try await SmartTubeClient(config: .init(host: host, port: port), session: session).ping()
    }

    public static func getPairCode(host: String, port: Int = 8497, session: URLSession = .shared) async throws -> PairCodeResponse {
        try await SmartTubeClient(config: .init(host: host, port: port), session: session).getPairCode()
    }

    public static func pair(host: String, port: Int = 8497, code: String, session: URLSession = .shared) async throws -> PairVerifyResponse {
        try await SmartTubeClient(config: .init(host: host, port: port), session: session).verifyPairCode(code, storeToken: false)
    }

    // MARK: Player State

    public func getPlayer() async throws -> PlayerState {
        try await request("GET", "/api/player", response: PlayerState.self)
    }

    // MARK: Transport

    @discardableResult public func play() async throws -> OKResponse { try await command("/api/player/play") }
    @discardableResult public func pause() async throws -> OKResponse { try await command("/api/player/pause") }
    @discardableResult public func toggle() async throws -> OKResponse { try await command("/api/player/toggle") }
    @discardableResult public func next() async throws -> OKResponse { try await command("/api/player/next") }
    @discardableResult public func previous() async throws -> OKResponse { try await command("/api/player/previous") }
    @discardableResult public func stop() async throws -> OKResponse { try await command("/api/player/stop") }
    @discardableResult public func reload() async throws -> OKResponse { try await command("/api/player/reload") }

    @discardableResult
    public func seek(positionMs: Int) async throws -> SeekResponse {
        try await request("POST", "/api/player/seek", body: SeekBody(position_ms: positionMs), response: SeekResponse.self)
    }

    // MARK: Playback Settings

    public func getSpeed() async throws -> SpeedState {
        try await request("GET", "/api/player/speed", response: SpeedState.self)
    }

    @discardableResult
    public func setSpeed(_ speed: Double) async throws -> OKResponse {
        try await request("PUT", "/api/player/speed", body: SpeedBody(speed: speed), response: OKResponse.self)
    }

    public func getVolume() async throws -> PlaybackVolumeState {
        try await request("GET", "/api/player/volume", response: PlaybackVolumeState.self)
    }

    @discardableResult
    public func setVolume(_ volume: Double) async throws -> OKResponse {
        try await request("PUT", "/api/player/volume", body: VolumeBody(volume: volume), response: OKResponse.self)
    }

    public func getPitch() async throws -> PitchState {
        try await request("GET", "/api/player/pitch", response: PitchState.self)
    }

    @discardableResult
    public func setPitch(_ pitch: Double) async throws -> OKResponse {
        try await request("PUT", "/api/player/pitch", body: PitchBody(pitch: pitch), response: OKResponse.self)
    }

    public func getMute() async throws -> MuteState {
        try await request("GET", "/api/player/mute", response: MuteState.self)
    }

    @discardableResult
    public func toggleMute() async throws -> OKResponse {
        try await command("/api/player/mute/toggle")
    }

    public func getSubtitleState() async throws -> SubtitleState {
        try await request("GET", "/api/player/subtitle", response: SubtitleState.self)
    }

    @discardableResult
    public func toggleSubtitles() async throws -> OKResponse {
        try await command("/api/player/subtitle/toggle")
    }

    // MARK: Track Selection

    public func getVideoFormats() async throws -> [VideoFormat] {
        let items = try await request("GET", "/api/player/formats/video", response: [VideoFormat].self)
        return items.filter { !$0.formatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func getAudioFormats() async throws -> [AudioFormat] {
        let items = try await request("GET", "/api/player/formats/audio", response: [AudioFormat].self)
        return items.filter { !$0.formatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func getSubtitleFormats() async throws -> [SubtitleFormat] {
        let items = try await request("GET", "/api/player/formats/subtitle", response: [SubtitleFormat].self)
        return items.filter { !$0.formatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func getSelectedTracks() async throws -> SelectedTracksResponse {
        try await request("GET", "/api/player/formats/selected", response: SelectedTracksResponse.self)
    }

    @discardableResult
    public func setVideoFormat(_ formatId: String) async throws -> OKResponse {
        try await request("PUT", "/api/player/formats/video", body: FormatIdBody(formatId: formatId), response: OKResponse.self)
    }

    @discardableResult
    public func setAudioFormat(_ formatId: String) async throws -> OKResponse {
        try await request("PUT", "/api/player/formats/audio", body: FormatIdBody(formatId: formatId), response: OKResponse.self)
    }

    @discardableResult
    public func setSubtitleFormat(_ formatId: String?) async throws -> OKResponse {
        try await request("PUT", "/api/player/formats/subtitle", body: FormatIdBody(formatId: formatId), response: OKResponse.self)
    }

    // MARK: Video Manipulation

    public func getResizeMode() async throws -> ResizeState {
        try await request("GET", "/api/player/video/resize", response: ResizeState.self)
    }

    @discardableResult
    public func setResizeMode(_ mode: Int) async throws -> OKResponse {
        try await request("PUT", "/api/player/video/resize", body: ResizeBody(mode: mode), response: OKResponse.self)
    }

    public func getZoom() async throws -> ZoomState {
        try await request("GET", "/api/player/video/zoom", response: ZoomState.self)
    }

    @discardableResult
    public func setZoom(_ zoom: Int) async throws -> OKResponse {
        try await request("PUT", "/api/player/video/zoom", body: ZoomBody(zoom: zoom), response: OKResponse.self)
    }

    public func getRotation() async throws -> RotationState {
        try await request("GET", "/api/player/video/rotation", response: RotationState.self)
    }

    @discardableResult
    public func setRotation(angle: Int) async throws -> OKResponse {
        try await request("PUT", "/api/player/video/rotation", body: RotationBody(angle: angle), response: OKResponse.self)
    }

    public func getFlip() async throws -> FlipState {
        try await request("GET", "/api/player/video/flip", response: FlipState.self)
    }

    @discardableResult
    public func setFlip(enabled: Bool) async throws -> OKResponse {
        try await request("PUT", "/api/player/video/flip", body: FlipBody(enabled: enabled), response: OKResponse.self)
    }

    // MARK: Content

    @discardableResult
    public func openContent(_ content: OpenContentRequest) async throws -> OKResponse {
        try await request("POST", "/api/content/open", body: content, response: OKResponse.self)
    }

    @discardableResult
    public func openURL(_ url: String, positionMs: Int? = nil) async throws -> OKResponse {
        try await openContent(.url(url, positionMs: positionMs))
    }

    @discardableResult
    public func openVideoId(_ videoId: String, positionMs: Int? = nil) async throws -> OKResponse {
        try await openContent(.videoId(videoId, positionMs: positionMs))
    }

    @discardableResult
    public func openPlaylistVideo(videoId: String, playlistId: String, playlistIndex: Int) async throws -> OKResponse {
        try await openContent(.playlist(videoId: videoId, playlistId: playlistId, playlistIndex: playlistIndex))
    }

    @discardableResult
    public func searchAndPlay(_ query: String) async throws -> OKResponse {
        try await request("POST", "/api/content/search", body: SearchBody(query: query), response: OKResponse.self)
    }

    /// Search YouTube and return the result list without starting playback.
    public func searchResults(_ query: String, limit: Int = 20) async throws -> [SuggestionItem] {
        try await request(
            "GET",
            "/api/content/search/results",
            query: ["query": query, "limit": String(limit)],
            response: [SuggestionItem].self
        )
    }

    public func getSuggestions() async throws -> [SuggestionItem] {
        try await request("GET", "/api/content/suggestions", response: [SuggestionItem].self)
    }

    /// The user's Home recommendations (not the related-videos list of the current video).
    public func getRecommended() async throws -> [SuggestionItem] {
        try await request("GET", "/api/content/recommended", response: [SuggestionItem].self)
    }

    @discardableResult
    public func playSuggestion(index: Int) async throws -> OKResponse {
        try await command("/api/content/suggestions/\(index)")
    }

    /// Play a suggestion by video ID — immune to the list refreshing (stale indexes).
    @discardableResult
    public func playSuggestion(videoId: String) async throws -> OKResponse {
        try await command("/api/content/suggestions/\(videoId)")
    }

    // MARK: Queue

    public func getQueue() async throws -> [QueueItem] {
        try await request("GET", "/api/player/queue", response: [QueueItem].self)
    }

    @discardableResult
    public func addToQueue(videoId: String) async throws -> OKResponse {
        try await request("POST", "/api/player/queue", body: QueueVideoBody(video_id: videoId), response: OKResponse.self)
    }

    @discardableResult
    public func playNext(videoId: String) async throws -> OKResponse {
        try await request("POST", "/api/player/queue/next", body: QueueVideoBody(video_id: videoId), response: OKResponse.self)
    }

    @discardableResult
    public func removeFromQueue(videoId: String) async throws -> OKResponse {
        try await request("DELETE", "/api/player/queue", body: QueueVideoBody(video_id: videoId), response: OKResponse.self)
    }

    @discardableResult
    public func clearQueue() async throws -> OKResponse {
        try await command("/api/player/queue/clear")
    }

    // MARK: Theater Control

    public func getTheater() async throws -> TheaterState {
        try await request("GET", "/api/theater", response: TheaterState.self)
    }

    public func getTheaterVolume() async throws -> TheaterVolumeState {
        try await request("GET", "/api/theater/volume", response: TheaterVolumeState.self)
    }

    @discardableResult
    public func setTheaterVolume(_ volume: Int) async throws -> OKResponse {
        let target = max(0, min(100, volume))
        do {
            return try await request("PUT", "/api/theater/volume", body: TheaterVolumeBody(volume: target), response: OKResponse.self)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            guard message.contains("422") || message.localizedCaseInsensitiveContains("Invalid JSON") else {
                throw error
            }

            let volumeState = try? await getTheaterVolume()
            let theaterState = volumeState == nil ? (try? await getTheater()) : nil
            let current = volumeState?.volume ?? theaterState?.volume ?? target
            let delta = target - current
            if delta == 0 { return OKResponse(ok: true) }

            for _ in 0..<min(abs(delta), 100) {
                if delta > 0 {
                    _ = try await theaterVolumeUp()
                } else {
                    _ = try await theaterVolumeDown()
                }
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
            return OKResponse(ok: true)
        }
    }

    @discardableResult public func theaterVolumeUp() async throws -> OKResponse { try await command("/api/theater/volume/up") }
    @discardableResult public func theaterVolumeDown() async throws -> OKResponse { try await command("/api/theater/volume/down") }
    @discardableResult public func toggleTheaterMute() async throws -> OKResponse { try await command("/api/theater/mute/toggle") }
    @discardableResult public func toggleTheaterPower() async throws -> OKResponse { try await command("/api/theater/power/toggle") }

    // MARK: System Control

    @discardableResult
    public func dpad(_ key: DPadKey) async throws -> OKResponse {
        try await request("GET", "/api/system/dpad", query: ["key": key.rawValue], response: OKResponse.self)
    }

    @discardableResult
    public func voice(_ action: VoiceAction = .start) async throws -> OKResponse {
        try await request("POST", "/api/system/voice", body: VoiceBody(action: action), response: OKResponse.self)
    }

    // MARK: Raw / Escape Hatch

    public func rawJSON(method: String, path: String, body: JSONValue? = nil, auth: Bool = true) async throws -> JSONValue {
        if let body {
            return try await request(method, path, auth: auth, body: body, response: JSONValue.self)
        }
        return try await request(method, path, auth: auth, response: JSONValue.self)
    }

    // MARK: Private Request Layer

    @discardableResult
    private func command(_ path: String, retries: Int = 2) async throws -> OKResponse {
        var lastError: Error?

        for attempt in 0...retries {
            do {
                return try await command(path)
            } catch {
                lastError = error
                let msg = String(describing: error)
                let shouldRetry = msg.contains("503") || msg.localizedCaseInsensitiveContains("Internal error")
                if attempt < retries && shouldRetry {
                    try? await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                    continue
                }
                throw error
            }
        }

        throw lastError ?? SmartTubeError.emptyResponse
    }

    private func command(_ path: String) async throws -> OKResponse {
        // Important: do not send `{}` here. SmartTube/NanoHTTPD no-body POST
        // handlers may leave that body unread on keep-alive connections, causing
        // the next request to be parsed as "{}POST".
        try await request("POST", path, response: OKResponse.self)
    }

    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [String: String?] = [:],
        auth: Bool = true,
        response: T.Type
    ) async throws -> T {
        try await request(method, path, query: query, auth: auth, body: Optional<EmptyBody>.none, response: response)
    }

    private func request<B: Encodable, T: Decodable>(
        _ method: String,
        _ path: String,
        query: [String: String?] = [:],
        auth: Bool = true,
        body: B?,
        response: T.Type
    ) async throws -> T {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw SmartTubeError.invalidURL
        }

        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = cleanPath
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else { throw SmartTubeError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if auth {
            guard let token = config.token, !token.isEmpty else { throw SmartTubeError.missingToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            do {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try encoder.encode(body)
                request.setValue(String(request.httpBody?.count ?? 0), forHTTPHeaderField: "Content-Length")
            } catch {
                throw SmartTubeError.encoding(error)
            }
        }

        let (data, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else { throw SmartTubeError.invalidResponse }

        if data.isEmpty {
            if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T { return empty }
            throw SmartTubeError.emptyResponse
        }

        if let apiEnvelope = try? decoder.decode(SmartTubeAPIErrorEnvelope.self, from: data) {
            throw SmartTubeError.apiError(code: apiEnvelope.error.code, message: apiEnvelope.error.message)
        }

        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8)
            throw SmartTubeError.httpStatus(http.statusCode, raw)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8)
            throw SmartTubeError.decoding(error, raw: raw)
        }
    }
}

private struct EmptyResponse: Decodable {
    init() {}
}

// MARK: - WebSocket Client

public enum SmartTubeWebSocketEvent: Sendable, Equatable {
    case hello(apiVersion: String?, deviceName: String?)
    case stateUpdate(PlayerState)
    case json(JSONValue)
}

public struct SmartTubeWebSocketMessage: Decodable, Sendable, Equatable {
    public let type: String
    public let apiVersion: String?
    public let deviceName: String?
    public let data: PlayerState?
    public let rawData: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case apiVersion = "api_version"
        case deviceName = "device_name"
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        data = (try? container.decodeIfPresent(PlayerState.self, forKey: .data)) ?? nil
        rawData = (try? container.decodeIfPresent(JSONValue.self, forKey: .data)) ?? nil
    }
}

public final class SmartTubeWebSocketClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (SmartTubeWebSocketEvent) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void
    public typealias CloseHandler = @Sendable () -> Void

    private let config: SmartTubeConfig
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "SmartTubeWebSocketClient.lock")

    public var onEvent: EventHandler?
    public var onError: ErrorHandler?
    public var onClose: CloseHandler?

    public private(set) var isConnected: Bool = false

    public init(
        config: SmartTubeConfig,
        session: URLSession = .shared,
        onEvent: EventHandler? = nil,
        onError: ErrorHandler? = nil,
        onClose: CloseHandler? = nil
    ) {
        self.config = config
        self.session = session
        self.onEvent = onEvent
        self.onError = onError
        self.onClose = onClose
    }

    public func connect() throws {
        guard let url = config.webSocketURL else { throw SmartTubeError.missingToken }
        let task = session.webSocketTask(with: url)
        queue.sync {
            self.task = task
            self.isConnected = true
        }
        task.resume()
        receiveLoop()
        keepAliveLoop(task: task)
    }

    /// NanoHTTPD closes sockets after ~5s without a READ; server pushes don't count.
    /// Pinging every 3s forces the server to read, keeping the connection alive.
    private func keepAliveLoop(task: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.queue.sync(execute: { self.task === task && self.isConnected }) else { return }
                task.sendPing { _ in }
            }
        }
    }

    public func disconnect(code: URLSessionWebSocketTask.CloseCode = .normalClosure, reason: Data? = nil) {
        queue.sync {
            self.isConnected = false
            self.task?.cancel(with: code, reason: reason)
            self.task = nil
        }
        onClose?()
    }

    public func send(action: String, params: [String: Any] = [:]) throws {
        let currentTask = queue.sync { task }
        guard let currentTask else { throw SmartTubeError.websocketNotConnected }

        var object = params
        object["action"] = action

        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let text = String(decoding: data, as: UTF8.self)
        currentTask.send(.string(text)) { [weak self] error in
            if let error { self?.onError?(error) }
        }
    }

    public func sendJSON(_ object: [String: Any]) throws {
        let currentTask = queue.sync { task }
        guard let currentTask else { throw SmartTubeError.websocketNotConnected }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        currentTask.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error { self?.onError?(error) }
        }
    }

    // Convenience WebSocket commands
    public func play() throws { try send(action: "play") }
    public func pause() throws { try send(action: "pause") }
    public func toggle() throws { try send(action: "toggle") }
    public func seek(positionMs: Int) throws { try send(action: "seek", params: ["position_ms": positionMs]) }
    public func next() throws { try send(action: "next") }
    public func previous() throws { try send(action: "previous") }
    public func stop() throws { try send(action: "stop") }
    public func reload() throws { try send(action: "reload") }
    public func setSpeed(_ speed: Double) throws { try send(action: "set_speed", params: ["speed": speed]) }
    public func setVolume(_ volume: Double) throws { try send(action: "set_volume", params: ["volume": volume]) }
    public func setVideoFormat(_ formatId: String) throws { try send(action: "set_video_format", params: ["format_id": formatId]) }
    public func setAudioFormat(_ formatId: String) throws { try send(action: "set_audio_format", params: ["format_id": formatId]) }
    public func setSubtitleFormat(_ formatId: String?) throws { try send(action: "set_subtitle_format", params: ["format_id": formatId ?? NSNull()]) }
    public func toggleSubtitles() throws { try send(action: "toggle_subtitles") }
    public func toggleMute() throws { try send(action: "toggle_mute") }
    public func search(_ query: String) throws { try send(action: "search", params: ["query": query]) }
    public func addToQueue(videoId: String) throws { try send(action: "add_to_queue", params: ["video_id": videoId]) }
    public func playNext(videoId: String) throws { try send(action: "play_next", params: ["video_id": videoId]) }
    public func removeFromQueue(videoId: String) throws { try send(action: "remove_from_queue", params: ["video_id": videoId]) }
    public func clearQueue() throws { try send(action: "clear_queue") }
    public func getQueue() throws { try send(action: "get_queue") }
    public func theaterPowerToggle() throws { try send(action: "theater_power_toggle") }
    public func theaterGetState() throws { try send(action: "theater_get_state") }
    public func getState() throws { try send(action: "get_state") }

    private func receiveLoop() {
        let currentTask = queue.sync { task }
        guard let currentTask else { return }

        currentTask.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                do {
                    let data: Data
                    switch message {
                    case .string(let text):
                        data = Data(text.utf8)
                    case .data(let incomingData):
                        data = incomingData
                    @unknown default:
                        self.receiveLoop()
                        return
                    }
                    try self.handleMessage(data)
                    self.receiveLoop()
                } catch {
                    self.onError?(error)
                    self.receiveLoop()
                }

            case .failure(let error):
                self.queue.sync {
                    self.isConnected = false
                    self.task = nil
                }
                self.onError?(error)
                self.onClose?()
            }
        }
    }

    private func handleMessage(_ data: Data) throws {
        let msg = try decoder.decode(SmartTubeWebSocketMessage.self, from: data)
        switch msg.type {
        case "hello":
            onEvent?(.hello(apiVersion: msg.apiVersion, deviceName: msg.deviceName))
        case "state_update":
            if let state = msg.data {
                onEvent?(.stateUpdate(state))
            } else if let raw = msg.rawData {
                onEvent?(.json(.object(["type": .string(msg.type), "data": raw])))
            }
        default:
            if let value = try? decoder.decode(JSONValue.self, from: data) {
                onEvent?(.json(value))
            }
        }
    }
}

// MARK: - Discovery

public enum SmartTubeDiscovery {
    public static func discoverUDP(port: Int = 8497, timeout: TimeInterval = 2.0) async throws -> [DiscoveryDevice] {
        #if canImport(Darwin)
        return try await Task.detached(priority: .userInitiated) {
            try discoverUDPBlocking(port: port, timeout: timeout)
        }.value
        #else
        throw SmartTubeError.socketUnsupported
        #endif
    }

    public static func ping(host: String, port: Int = 8497, timeout: TimeInterval = 2.0) async -> PingResponse? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        return try? await SmartTubeClient.ping(host: host, port: port, session: session)
    }

    public static func scanSubnet(
        prefix: String,
        port: Int = 8497,
        range: ClosedRange<Int> = 1...254,
        timeout: TimeInterval = 0.8,
        maxConcurrent: Int = 32
    ) async -> [(host: String, ping: PingResponse)] {
        await withTaskGroup(of: (String, PingResponse)?.self) { group in
            var iterator = range.makeIterator()
            var active = 0
            var results: [(host: String, ping: PingResponse)] = []

            func enqueueNext() {
                guard let lastOctet = iterator.next() else { return }
                active += 1
                let host = "\(prefix).\(lastOctet)"
                group.addTask {
                    if let ping = await SmartTubeDiscovery.ping(host: host, port: port, timeout: timeout) {
                        return (host, ping)
                    }
                    return nil
                }
            }

            for _ in 0..<maxConcurrent { enqueueNext() }

            while active > 0, let item = await group.next() {
                active -= 1
                if let item { results.append(item) }
                enqueueNext()
            }

            return results.sorted { $0.host < $1.host }
        }
    }

    #if canImport(Darwin)
    private static func discoverUDPBlocking(port: Int, timeout: TimeInterval) throws -> [DiscoveryDevice] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw SmartTubeError.socketFailed(String(cString: strerror(errno))) }
        defer { close(sock) }

        var yes: Int32 = 1
        guard setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SmartTubeError.socketFailed("setsockopt SO_BROADCAST failed: \(String(cString: strerror(errno)))")
        }

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = in_port_t(0).bigEndian
        bindAddr.sin_addr.s_addr = in_addr_t(INADDR_ANY).bigEndian

        let bindResult = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw SmartTubeError.socketFailed("bind failed: \(String(cString: strerror(errno)))")
        }

        let probe = Data(#"{"action":"discover"}"#.utf8)
        var broadcast = sockaddr_in()
        broadcast.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        broadcast.sin_family = sa_family_t(AF_INET)
        broadcast.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "255.255.255.255", &broadcast.sin_addr)

        let sent = probe.withUnsafeBytes { payloadPointer in
            withUnsafePointer(to: &broadcast) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    sendto(sock, payloadPointer.baseAddress, probe.count, 0, addressPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0 else {
            throw SmartTubeError.socketFailed("sendto failed: \(String(cString: strerror(errno)))")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var devicesByKey: [String: DiscoveryDevice] = [:]
        let decoder = JSONDecoder()

        while Date() < deadline {
            var readfds = fd_set()
            FD_ZERO(&readfds)
            FD_SET(sock, &readfds)

            let remaining = max(0.05, deadline.timeIntervalSinceNow)
            var tv = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            let ready = select(sock + 1, &readfds, nil, nil, &tv)
            if ready < 0 {
                if errno == EINTR { continue }
                throw SmartTubeError.socketFailed("select failed: \(String(cString: strerror(errno)))")
            }
            if ready == 0 { break }

            var buffer = [UInt8](repeating: 0, count: 4096)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let received = withUnsafeMutablePointer(to: &from) { fromPointer in
                fromPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddressPointer in
                    recvfrom(sock, &buffer, buffer.count, 0, sockAddressPointer, &fromLen)
                }
            }

            guard received > 0 else { continue }

            let data = Data(buffer.prefix(received))
            guard var device = try? decoder.decode(DiscoveryDevice.self, from: data) else { continue }

            var addressBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = from.sin_addr
            inet_ntop(AF_INET, &addr, &addressBuffer, socklen_t(INET_ADDRSTRLEN))
            let host = String(cString: addressBuffer)
            device.host = host

            let key = device.deviceId.isEmpty ? host : device.deviceId
            devicesByKey[key] = device
        }

        return Array(devicesByKey.values).sorted { ($0.host ?? "") < ($1.host ?? "") }
    }
    #endif
}

#if canImport(Darwin)
// MARK: - Darwin fd_set Helpers

private func fdSet(_ fd: Int32, set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    let mask = Int32(1 << bitOffset)

    switch intOffset {
    case 0: set.fds_bits.0 |= mask
    case 1: set.fds_bits.1 |= mask
    case 2: set.fds_bits.2 |= mask
    case 3: set.fds_bits.3 |= mask
    case 4: set.fds_bits.4 |= mask
    case 5: set.fds_bits.5 |= mask
    case 6: set.fds_bits.6 |= mask
    case 7: set.fds_bits.7 |= mask
    case 8: set.fds_bits.8 |= mask
    case 9: set.fds_bits.9 |= mask
    case 10: set.fds_bits.10 |= mask
    case 11: set.fds_bits.11 |= mask
    case 12: set.fds_bits.12 |= mask
    case 13: set.fds_bits.13 |= mask
    case 14: set.fds_bits.14 |= mask
    case 15: set.fds_bits.15 |= mask
    case 16: set.fds_bits.16 |= mask
    case 17: set.fds_bits.17 |= mask
    case 18: set.fds_bits.18 |= mask
    case 19: set.fds_bits.19 |= mask
    case 20: set.fds_bits.20 |= mask
    case 21: set.fds_bits.21 |= mask
    case 22: set.fds_bits.22 |= mask
    case 23: set.fds_bits.23 |= mask
    case 24: set.fds_bits.24 |= mask
    case 25: set.fds_bits.25 |= mask
    case 26: set.fds_bits.26 |= mask
    case 27: set.fds_bits.27 |= mask
    case 28: set.fds_bits.28 |= mask
    case 29: set.fds_bits.29 |= mask
    case 30: set.fds_bits.30 |= mask
    case 31: set.fds_bits.31 |= mask
    default: break
    }
}

private func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

private func FD_SET(_ fd: Int32, _ set: inout fd_set) { fdSet(fd, set: &set) }
private func FD_ZERO(_ set: inout fd_set) { fdZero(&set) }
#endif

// MARK: - Example Usage

/*
Task {
    do {
        // 1) Discover TV. If UDP is blocked, use manual IP or scanSubnet(prefix: "192.168.1").
        let devices = try await SmartTubeDiscovery.discoverUDP(timeout: 2)
        let host = devices.first?.host ?? "192.168.1.44"

        // 2) Pair.
        let client = SmartTubeClient(config: SmartTubeConfig(host: host))
        let pair = try await client.getPairCode()
        print("Enter this code on your client UI:", pair.code)

        // User enters code here.
        let verified = try await client.verifyPairCode("482 917")
        print("Paired with", verified.deviceName, "token:", verified.token)

        // 3) Use REST commands.
        try await client.openURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        try await client.setVolume(0.85)
        try await client.seek(positionMs: 60_000)
        let state = try await client.getPlayer()
        print(state.video?.title ?? "No video")

        // 4) Use WebSocket updates.
        let ws = SmartTubeWebSocketClient(config: SmartTubeConfig(host: host, token: verified.token)) { event in
            switch event {
            case .hello(_, let deviceName): print("WS hello", deviceName ?? "")
            case .stateUpdate(let state): print("State", state.state.rawValue, state.positionMs ?? 0)
            case .json(let json): print("Other", json)
            }
        } onError: { error in
            print("WS error", error)
        } onClose: {
            print("WS closed")
        }
        try ws.connect()
        try ws.toggle()
    } catch {
        print("SmartTube error:", error.localizedDescription)
    }
}
*/
