import Foundation
import OSLog

enum VoiceTelemetrySpanName: String {
    case total = "voice.total.mouth_to_ear"
    case capture = "voice.client.capture"
    case upload = "voice.upload"
    case play = "voice.client.play"
}

struct VoiceTelemetryCorrelation: Sendable {
    let voiceSessionID: String
    let voiceTurnID: String
    let clientKind: String = "ios"

    var headers: [String: String] {
        [
            "x-orchet-session-id": voiceSessionID,
            "x-orchet-turn-id": voiceTurnID,
            "x-orchet-client-kind": clientKind,
        ]
    }
}

typealias VoiceTelemetryAttributes = [String: String]

@MainActor
final class VoiceTelemetry {
    static let shared = VoiceTelemetry()

    private let logger = Logger(subsystem: "com.lumo.rentals.ios", category: "voice.telemetry")
    private let signposter: OSSignposter
    private let voiceSessionID = "voice_session_\(UUID().uuidString)"
    private var activeTurn: VoiceTelemetryTurn?

    private init() {
        self.signposter = OSSignposter(logger: logger)
    }

    func beginTurn() -> VoiceTelemetryTurn {
        if let activeTurn {
            finishTurn(activeTurn, attributes: [
                "voice.cancelled": "true",
                "voice.cancel_reason": "new_voice_turn",
            ])
        }
        let turn = VoiceTelemetryTurn(
            correlation: VoiceTelemetryCorrelation(
                voiceSessionID: voiceSessionID,
                voiceTurnID: "voice_turn_\(UUID().uuidString)"
            ),
            signposter: signposter,
            logger: logger
        )
        activeTurn = turn
        logger.info(
            "voice.turn.start voice.session_id=\(turn.correlation.voiceSessionID, privacy: .public) voice.turn_id=\(turn.correlation.voiceTurnID, privacy: .public) client.kind=ios"
        )
        return turn
    }

    func currentTurn() -> VoiceTelemetryTurn? {
        activeTurn
    }

    func finishTurn(_ turn: VoiceTelemetryTurn?, attributes: VoiceTelemetryAttributes = [:]) {
        guard let turn else { return }
        turn.endOpenSpans(attributes: attributes)
        if activeTurn === turn {
            activeTurn = nil
            logger.info(
                "voice.turn.end voice.session_id=\(turn.correlation.voiceSessionID, privacy: .public) voice.turn_id=\(turn.correlation.voiceTurnID, privacy: .public) client.kind=ios attributes=\(Self.format(attributes), privacy: .public)"
            )
        }
    }

    static func format(_ attributes: VoiceTelemetryAttributes) -> String {
        attributes
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}

@MainActor
final class VoiceTelemetryTurn {
    let correlation: VoiceTelemetryCorrelation

    private let signposter: OSSignposter
    private let logger: Logger
    private var captureSpan: VoiceTelemetrySpan?
    private var uploadSpan: VoiceTelemetrySpan?
    private var totalSpan: VoiceTelemetrySpan?
    private var playSpan: VoiceTelemetrySpan?

    init(
        correlation: VoiceTelemetryCorrelation,
        signposter: OSSignposter,
        logger: Logger
    ) {
        self.correlation = correlation
        self.signposter = signposter
        self.logger = logger
    }

    func startCapture(attributes: VoiceTelemetryAttributes = [:]) {
        guard captureSpan == nil else { return }
        captureSpan = startSpan(.capture, attributes: attributes)
    }

    func markFirstAudioChunkReady(byteCount: Int) {
        endCapture(attributes: [
            "voice.audio_bytes": "\(byteCount)",
            "voice.audio_format": "linear16",
            "voice.sample_rate": "16000",
        ])
        startUploadIfNeeded(attributes: [
            "voice.audio_bytes_first_chunk": "\(byteCount)",
            "voice.stt.transport": "deepgram.websocket",
        ])
    }

    func markTranscriptFinal(transcript: String) {
        endUpload(attributes: [
            "voice.stt.final_chars": "\(transcript.count)",
            "voice.stt.transport": "deepgram.websocket",
        ])
        startTotalIfNeeded(attributes: [
            "voice.stt.final_chars": "\(transcript.count)",
        ])
    }

    func startPlayOnce(audioBytes: Int) {
        guard playSpan == nil else { return }
        playSpan = startSpan(.play, attributes: [
            "voice.tts.audio_bytes_first_chunk": "\(audioBytes)",
            "voice.tts.transport": "deepgram.websocket",
        ])
    }

    func markFirstAudibleSample(audioBytes: Int) {
        endPlay(attributes: [
            "voice.tts.audio_bytes_first_chunk": "\(audioBytes)",
        ])
        endTotal(attributes: [
            "voice.tts.audio_bytes_first_chunk": "\(audioBytes)",
        ])
    }

    func endOpenSpans(attributes: VoiceTelemetryAttributes = [:]) {
        endCapture(attributes: attributes)
        endUpload(attributes: attributes)
        endPlay(attributes: attributes)
        endTotal(attributes: attributes)
    }

    private func startTotalIfNeeded(attributes: VoiceTelemetryAttributes = [:]) {
        guard totalSpan == nil else { return }
        totalSpan = startSpan(.total, attributes: attributes)
    }

    private func startUploadIfNeeded(attributes: VoiceTelemetryAttributes = [:]) {
        guard uploadSpan == nil else { return }
        uploadSpan = startSpan(.upload, attributes: attributes)
    }

    private func endCapture(attributes: VoiceTelemetryAttributes = [:]) {
        captureSpan?.end(attributes: attributes)
        captureSpan = nil
    }

    private func endUpload(attributes: VoiceTelemetryAttributes = [:]) {
        uploadSpan?.end(attributes: attributes)
        uploadSpan = nil
    }

    private func endTotal(attributes: VoiceTelemetryAttributes = [:]) {
        totalSpan?.end(attributes: attributes)
        totalSpan = nil
    }

    private func endPlay(attributes: VoiceTelemetryAttributes = [:]) {
        playSpan?.end(attributes: attributes)
        playSpan = nil
    }

    private func startSpan(
        _ name: VoiceTelemetrySpanName,
        attributes: VoiceTelemetryAttributes
    ) -> VoiceTelemetrySpan {
        VoiceTelemetrySpan(
            name: name,
            correlation: correlation,
            attributes: attributes,
            signposter: signposter,
            logger: logger
        )
    }
}

@MainActor
private final class VoiceTelemetrySpan {
    private let name: VoiceTelemetrySpanName
    private let correlation: VoiceTelemetryCorrelation
    private let attributes: VoiceTelemetryAttributes
    private let signposter: OSSignposter
    private let logger: Logger
    private let state: OSSignpostIntervalState
    private let startedAt = Date()
    private var ended = false

    init(
        name: VoiceTelemetrySpanName,
        correlation: VoiceTelemetryCorrelation,
        attributes: VoiceTelemetryAttributes,
        signposter: OSSignposter,
        logger: Logger
    ) {
        self.name = name
        self.correlation = correlation
        self.attributes = attributes
        self.signposter = signposter
        self.logger = logger
        let context = Self.contextString(correlation: correlation, attributes: attributes)
        switch name {
        case .total:
            self.state = signposter.beginInterval("voice.total.mouth_to_ear", "\(context, privacy: .public)")
        case .capture:
            self.state = signposter.beginInterval("voice.client.capture", "\(context, privacy: .public)")
        case .upload:
            self.state = signposter.beginInterval("voice.upload", "\(context, privacy: .public)")
        case .play:
            self.state = signposter.beginInterval("voice.client.play", "\(context, privacy: .public)")
        }
        logger.info(
            "voice.span.start span_name=\(name.rawValue, privacy: .public) voice.session_id=\(correlation.voiceSessionID, privacy: .public) voice.turn_id=\(correlation.voiceTurnID, privacy: .public) client.kind=ios attributes=\(VoiceTelemetry.format(attributes), privacy: .public)"
        )
    }

    func end(attributes endAttributes: VoiceTelemetryAttributes = [:]) {
        guard !ended else { return }
        ended = true
        let durationMs = Date().timeIntervalSince(startedAt) * 1000
        let merged = attributes.merging(endAttributes) { _, new in new }
        let context = Self.contextString(correlation: correlation, attributes: merged)
        switch name {
        case .total:
            signposter.endInterval("voice.total.mouth_to_ear", state, "\(context, privacy: .public)")
        case .capture:
            signposter.endInterval("voice.client.capture", state, "\(context, privacy: .public)")
        case .upload:
            signposter.endInterval("voice.upload", state, "\(context, privacy: .public)")
        case .play:
            signposter.endInterval("voice.client.play", state, "\(context, privacy: .public)")
        }
        logger.info(
            "voice.span.end span_name=\(self.name.rawValue, privacy: .public) duration_ms=\(durationMs, privacy: .public) voice.session_id=\(self.correlation.voiceSessionID, privacy: .public) voice.turn_id=\(self.correlation.voiceTurnID, privacy: .public) client.kind=ios attributes=\(VoiceTelemetry.format(merged), privacy: .public)"
        )
    }

    private static func contextString(
        correlation: VoiceTelemetryCorrelation,
        attributes: VoiceTelemetryAttributes
    ) -> String {
        let base = [
            "voice.session_id=\(correlation.voiceSessionID)",
            "voice.turn_id=\(correlation.voiceTurnID)",
            "client.kind=\(correlation.clientKind)",
        ]
        let extra = VoiceTelemetry.format(attributes)
        return extra.isEmpty ? base.joined(separator: " ") : (base + [extra]).joined(separator: " ")
    }
}
