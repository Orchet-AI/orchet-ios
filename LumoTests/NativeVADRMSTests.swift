import AVFoundation
import XCTest
@testable import Lumo

/// `NativeVADService.rmsDBFS` is a pure helper; verify it returns
/// sensible dBFS values for known inputs so the over/under threshold
/// decision in the VAD remains predictable as we tune the
/// `thresholdDBFS` constant.
final class NativeVADRMSTests: XCTestCase {

    private func makeBuffer(samples: [Float], sampleRate: Double = 16000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (i, s) in samples.enumerated() {
            channel[i] = s
        }
        return buffer
    }

    func test_rmsDBFS_silentBuffer_returnsFloor() {
        let buffer = makeBuffer(samples: Array(repeating: 0.0, count: 256))
        XCTAssertEqual(NativeVADService.rmsDBFS(buffer: buffer), -160, accuracy: 0.01)
    }

    func test_rmsDBFS_fullScaleSine_isNearZeroDBFS() {
        // Sine at ±1.0 has RMS = 1/sqrt(2) ≈ 0.707 → -3 dBFS.
        var samples = [Float]()
        for i in 0..<512 {
            samples.append(sinf(Float(i) * .pi * 2 / 64))
        }
        let buffer = makeBuffer(samples: samples)
        let db = NativeVADService.rmsDBFS(buffer: buffer)
        XCTAssertLessThan(db, 0)
        XCTAssertGreaterThan(db, -6)
    }

    func test_rmsDBFS_quietSpeech_isAboveDefaultThreshold() {
        // Pseudo-speech at ~0.01 RMS → -40 dBFS, comfortably above
        // the -45 dBFS detection floor.
        var samples = [Float]()
        for i in 0..<2048 {
            let phase = Float(i) * 0.1
            samples.append(0.01 * sinf(phase))
        }
        let buffer = makeBuffer(samples: samples)
        let db = NativeVADService.rmsDBFS(buffer: buffer)
        // Must be louder than -45 dBFS (the speech threshold) but
        // quieter than 0 dBFS (clipping).
        XCTAssertGreaterThan(db, -45)
        XCTAssertLessThan(db, 0)
    }
}
