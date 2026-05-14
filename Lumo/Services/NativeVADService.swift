import AVFoundation
import Foundation

/// On-device VAD (Voice Activity Detector) for the streaming voice
/// path. Sits in parallel to Daily's audio capture and informs the
/// barge-in decision: when the user starts speaking, we emit a
/// `barge_in { phase: speech_started }` app-message so the voice
/// service can interrupt its TTS.
///
/// Implementation: AVAudioEngine input tap, RMS computed over each
/// 16 kHz mono buffer, debounced over consecutive buffers. The web
/// path uses Silero (ONNX/WASM); on iOS we keep it light — RMS is
/// good enough for "is anyone talking right now?" and avoids
/// shipping a model.
///
/// Tuneable constants:
/// - `thresholdDBFS = -45`  (RMS threshold; below = silence)
/// - `speechFrames = 2`     (consecutive over-threshold buffers
///                           before declaring speech_started)
/// - `redemptionFrames = 14`(consecutive under-threshold buffers
///                           before declaring speech_ended)
///
/// These mirror the web Silero values in `VoiceMode.tsx`.
@MainActor
final class NativeVADService {
    enum Event {
        case speechStarted
        case speechEnded
    }

    var onEvent: ((Event) -> Void)?

    private let engine = AVAudioEngine()
    private var isRunning = false
    private var overCount = 0
    private var underCount = 0
    private var inSpeech = false

    private let thresholdDBFS: Float = -45.0
    private let speechFrames = 2
    private let redemptionFrames = 14

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Tap with the input's native format; downsampling to 16 kHz
        // mono is unnecessary for RMS computation since we only care
        // about energy. Buffer size 1024 ≈ 23 ms at 44.1 kHz / 64 ms
        // at 16 kHz — within the brief's "minSpeechFrames: 2" window.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.rmsDBFS(buffer: buffer)
            Task { @MainActor in self.process(level: level) }
        }
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        overCount = 0
        underCount = 0
        if inSpeech {
            inSpeech = false
            onEvent?(.speechEnded)
        }
    }

    private func process(level: Float) {
        let isOver = level >= thresholdDBFS
        if isOver {
            overCount += 1
            underCount = 0
            if !inSpeech && overCount >= speechFrames {
                inSpeech = true
                onEvent?(.speechStarted)
            }
        } else {
            underCount += 1
            overCount = 0
            if inSpeech && underCount >= redemptionFrames {
                inSpeech = false
                onEvent?(.speechEnded)
            }
        }
    }

    /// Convert a buffer's RMS amplitude to dBFS. Empty / silent
    /// buffers return -160 dBFS rather than -infinity so the
    /// downstream comparison stays well-defined.
    static func rmsDBFS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -160 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return -160 }
        let channel = channels[0]
        var sum: Float = 0
        for i in 0..<frameCount {
            let s = channel[i]
            sum += s * s
        }
        let mean = sum / Float(frameCount)
        guard mean > 0 else { return -160 }
        let rms = sqrtf(mean)
        // 20 * log10(rms / 1.0) — full-scale reference is 1.0 for
        // Float32 PCM.
        return 20 * log10f(rms)
    }
}
