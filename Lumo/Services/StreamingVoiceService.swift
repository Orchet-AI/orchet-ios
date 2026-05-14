import Combine
import Foundation

// ORCHET-IOS-PARITY-1 — streaming voice service.
//
// Owns the Daily WebRTC call to the orchet-voice Fly service. The
// caller (StreamingVoiceViewModel) drives lifecycle via start(...)
// and stop(); transcript + confirmation + migration events are
// published as Combine subjects for the chat surface to subscribe to.
//
// The Daily SDK binding lives behind StreamingVoiceTransport so the
// service is testable without a real CallClient. The default
// `LiveDailyTransport` adapter wraps `Daily.CallClient` — see
// `DailyCallTransport.swift` (added in the Part-C/D follow-up). Until
// that lands, instantiating the service with a real transport
// requires injecting one explicitly; the default initializer uses an
// `UnimplementedStreamingVoiceTransport` that surfaces a clean error
// state on .start so the legacy batch path keeps working.
//
// State machine:
//
//   idle ─► fetchingRoom ─► joining ─► connected
//                              │           │
//                              ▼           ▼
//                            error      disconnected (on stop or peer-leave)
//
// Subjects (broadcast as the data channel delivers app messages):
//   - userTranscript:           VoiceUserTranscriptMessage
//   - assistantTranscriptDelta: VoiceAssistantTranscriptDeltaMessage
//   - assistantTranscriptFinal: VoiceAssistantTranscriptFinalMessage
//   - confirmation:             VoiceShowConfirmationMessage (Part D)
//   - sessionMigrate:           VoiceSessionMigrateMessage   (Part D)
//   - marketplaceInstalled:     VoiceMarketplaceInstalledMessage (Part F stretch)
//
// Side note: barge-in app messages are produced by NativeVADService
// (Part C). This service exposes `sendAppMessage(_:)` for upstream
// barge-in / confirmation_resolved emissions.

// MARK: - Codable app-message payloads (mirror web data-channel types)

/// User speech as transcribed by the voice service's Deepgram step
/// and forwarded to all participants. iOS uses this to render the
/// user bubble inline without re-dispatching through chat /turn.
struct VoiceUserTranscriptMessage: Codable, Equatable {
    let type: String  // "voice_user_transcript"
    let voice_session_id: String
    let turn_id: String?
    let text: String
}

/// Delta token from the streaming voice LLM. NOT cumulative — caller
/// appends to the in-flight assistant message.
struct VoiceAssistantTranscriptDeltaMessage: Codable, Equatable {
    let type: String  // "voice_assistant_transcript_delta"
    let voice_session_id: String
    let turn_id: String?
    let text: String
}

/// Final, fully reconciled assistant text for the turn. Replaces the
/// in-flight message text in case any delta was dropped.
struct VoiceAssistantTranscriptFinalMessage: Codable, Equatable {
    let type: String  // "voice_assistant_transcript_final"
    let voice_session_id: String
    let turn_id: String?
    let text: String
}

/// High-risk action confirmation — rendered as a native sheet.
/// Detail key/value pairs surface as a label list.
struct VoiceShowConfirmationMessage: Codable, Equatable, Identifiable {
    struct Detail: Codable, Equatable {
        let label: String
        let value: String
    }

    let type: String  // "voice_show_confirmation"
    let voice_session_id: String
    let confirmation_id: String
    let title: String
    let summary: String?
    let details: [Detail]?
    let expires_at: String?  // ISO8601

    var id: String { confirmation_id }
}

/// Voice service is migrating the session to a different region.
/// Client should disconnect and re-`/voice/start` against the
/// target region.
struct VoiceSessionMigrateMessage: Codable, Equatable {
    let type: String  // "voice_session_migrate"
    let target_region: String?
}

/// Voice-driven marketplace install completed (low-risk path).
/// iOS surfaces a toast and refreshes the marketplace list.
struct VoiceMarketplaceInstalledMessage: Codable, Equatable {
    let type: String  // "voice_marketplace_installed"
    let agent_id: String
    let display_name: String?
}

// MARK: - Outgoing app messages

/// Local VAD reports speech_started / speech_ended so the voice
/// service can perform native barge-in on the assistant's TTS.
struct BargeInAppMessage: Encodable {
    enum Phase: String, Encodable {
        case speechStarted = "speech_started"
        case speechEnded = "speech_ended"
    }
    let type: String = "barge_in"
    let phase: Phase
    let client_sent_at: String
}

/// Reply to a `voice_show_confirmation` — accepted or cancelled.
/// The `result` block mirrors the `/voice/confirm-action` response so
/// the voice service can continue speaking with the right context.
struct ConfirmationResolvedAppMessage: Encodable {
    struct ResultBody: Encodable {
        let result: String  // "executed" | "cancelled"
        let voice_continuation_hint: String?
    }
    let type: String = "confirmation_resolved"
    let confirmation_id: String
    let accepted: Bool
    let result: ResultBody
}

// MARK: - HTTP response from /voice/start

/// Response shape the orchet-voice service returns on POST /voice/start.
/// `room_url` + `client_token` go into the Daily CallClient.join call;
/// `session_id` ties the call to subsequent /voice/turn and
/// /voice/confirm-action requests.
struct VoiceStartResponse: Decodable, Equatable {
    let room_url: String
    let client_token: String
    let session_id: String
}

// MARK: - Transport seam

/// Abstraction over the Daily CallClient so tests can drive the
/// service end-to-end without a real WebRTC session. The live
/// adapter that wraps `Daily.CallClient` lives in
/// `DailyCallTransport.swift` (Part-C/D follow-up).
protocol StreamingVoiceTransport: AnyObject {
    /// Join the Daily room. The transport invokes `onAppMessage` for
    /// every inbound data-channel payload (raw JSON bytes), and
    /// `onStateChange` when the connection state mutates.
    func join(
        roomURL: String,
        clientToken: String,
        onAppMessage: @escaping (Data) -> Void,
        onStateChange: @escaping (StreamingVoiceState) -> Void
    ) async throws

    /// Send an arbitrary Encodable payload over the data channel.
    func sendAppMessage(_ payload: Data) async throws

    /// Gracefully leave the room.
    func leave() async
}

/// Surfaced via the `state` Published so the UI can render
/// connecting / connected / error states.
enum StreamingVoiceState: Equatable {
    case idle
    case fetchingRoom
    case joining
    case connected
    case disconnected
    case error(String)
}

// MARK: - Service

@MainActor
final class StreamingVoiceService: ObservableObject {
    @Published private(set) var state: StreamingVoiceState = .idle
    @Published private(set) var lastError: String?

    // Inbound subjects — view model / chat parent subscribes.
    let userTranscript = PassthroughSubject<VoiceUserTranscriptMessage, Never>()
    let assistantTranscriptDelta = PassthroughSubject<VoiceAssistantTranscriptDeltaMessage, Never>()
    let assistantTranscriptFinal = PassthroughSubject<VoiceAssistantTranscriptFinalMessage, Never>()
    let confirmation = PassthroughSubject<VoiceShowConfirmationMessage, Never>()
    let sessionMigrate = PassthroughSubject<VoiceSessionMigrateMessage, Never>()
    let marketplaceInstalled = PassthroughSubject<VoiceMarketplaceInstalledMessage, Never>()

    private let baseURL: URL
    private let session: URLSession
    private let transport: StreamingVoiceTransport
    private let isoFormatter: ISO8601DateFormatter

    /// `currentSessionID` is populated on successful /voice/start and
    /// cleared on stop(). Outbound app-messages stamp it for the
    /// voice service's logs.
    private(set) var currentSessionID: String?

    init(
        baseURL: URL = VoiceBackendConfig.voiceServiceBaseURL,
        session: URLSession = .shared,
        transport: StreamingVoiceTransport = UnimplementedStreamingVoiceTransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.transport = transport
        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Start a streaming voice session. Returns the parsed
    /// `/voice/start` body so callers can store room ids if needed.
    @discardableResult
    func start(userJWT: String) async throws -> VoiceStartResponse {
        state = .fetchingRoom
        lastError = nil

        let url = baseURL.appendingPathComponent("voice/start")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !userJWT.isEmpty {
            req.setValue("Bearer \(userJWT)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = "voice/start failed (\(code))"
            state = .error(msg)
            lastError = msg
            throw StreamingVoiceError.startFailed(status: code)
        }

        let parsed: VoiceStartResponse
        do {
            parsed = try JSONDecoder().decode(VoiceStartResponse.self, from: data)
        } catch {
            let msg = "voice/start decode: \(error.localizedDescription)"
            state = .error(msg)
            lastError = msg
            throw StreamingVoiceError.decodeFailed
        }

        currentSessionID = parsed.session_id
        state = .joining
        do {
            try await transport.join(
                roomURL: parsed.room_url,
                clientToken: parsed.client_token,
                onAppMessage: { [weak self] data in
                    Task { @MainActor in self?.handleInbound(data) }
                },
                onStateChange: { [weak self] new in
                    Task { @MainActor in self?.state = new }
                }
            )
        } catch {
            let msg = "join failed: \(error.localizedDescription)"
            state = .error(msg)
            lastError = msg
            throw error
        }
        return parsed
    }

    func stop() async {
        await transport.leave()
        state = .disconnected
        currentSessionID = nil
    }

    /// Emits a `barge_in` event with the current timestamp. Called by
    /// `NativeVADService` (Part C) on speech_started / speech_ended.
    func sendBargeIn(_ phase: BargeInAppMessage.Phase) async {
        let msg = BargeInAppMessage(phase: phase, client_sent_at: isoFormatter.string(from: Date()))
        await sendEncodable(msg)
    }

    /// Sends a `confirmation_resolved` reply over the data channel
    /// after the user taps Confirm/Cancel on the native modal.
    func sendConfirmationResolved(_ msg: ConfirmationResolvedAppMessage) async {
        await sendEncodable(msg)
    }

    // MARK: - Inbound routing

    /// Decode and route an inbound app-message Data payload. Visible
    /// for unit tests; pass synthetic JSON to assert routing.
    func handleInbound(_ raw: Data) {
        guard let type = peekType(raw) else { return }
        let decoder = JSONDecoder()
        switch type {
        case "voice_user_transcript":
            if let m = try? decoder.decode(VoiceUserTranscriptMessage.self, from: raw) {
                userTranscript.send(m)
            }
        case "voice_assistant_transcript_delta":
            if let m = try? decoder.decode(VoiceAssistantTranscriptDeltaMessage.self, from: raw) {
                assistantTranscriptDelta.send(m)
            }
        case "voice_assistant_transcript_final":
            if let m = try? decoder.decode(VoiceAssistantTranscriptFinalMessage.self, from: raw) {
                assistantTranscriptFinal.send(m)
            }
        case "voice_show_confirmation":
            if let m = try? decoder.decode(VoiceShowConfirmationMessage.self, from: raw) {
                confirmation.send(m)
            }
        case "voice_session_migrate":
            if let m = try? decoder.decode(VoiceSessionMigrateMessage.self, from: raw) {
                sessionMigrate.send(m)
            }
        case "voice_marketplace_installed":
            if let m = try? decoder.decode(VoiceMarketplaceInstalledMessage.self, from: raw) {
                marketplaceInstalled.send(m)
            }
        default:
            // Unknown types are dropped silently — the voice service
            // may emit additional kinds the iOS client doesn't
            // surface (telemetry, server-only signals).
            break
        }
    }

    private func peekType(_ raw: Data) -> String? {
        struct Envelope: Decodable { let type: String }
        return try? JSONDecoder().decode(Envelope.self, from: raw).type
    }

    private func sendEncodable<T: Encodable>(_ payload: T) async {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? await transport.sendAppMessage(data)
    }
}

enum StreamingVoiceError: Error, Equatable {
    case startFailed(status: Int)
    case decodeFailed
    case notImplemented
}

/// Default transport — fails fast if the streaming path is
/// instantiated before the Daily-backed adapter is wired. Keeps the
/// legacy batch surface working by surfacing a clear error rather
/// than crashing.
final class UnimplementedStreamingVoiceTransport: StreamingVoiceTransport {
    func join(
        roomURL: String,
        clientToken: String,
        onAppMessage: @escaping (Data) -> Void,
        onStateChange: @escaping (StreamingVoiceState) -> Void
    ) async throws {
        onStateChange(.error("Daily transport not wired — install streaming follow-up"))
        throw StreamingVoiceError.notImplemented
    }
    func sendAppMessage(_ payload: Data) async throws {
        throw StreamingVoiceError.notImplemented
    }
    func leave() async {}
}
