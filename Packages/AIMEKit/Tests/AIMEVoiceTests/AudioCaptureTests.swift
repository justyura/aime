import AVFoundation
import XCTest
@testable import AIMEVoice

final class AudioCaptureTests: XCTestCase {
    func testPrerollAndLongLiveRecordingPreserveBeginningInWAV() {
        let delivery = CaptureAudioDelivery()
        let router = PrerollAudioRouter(maxBytes: 96_000)
        let graph = delivery.replaceGraph()
        router.startBuffering()
        delivery.begin { router.append($0) }
        let head = Data(repeating: 1, count: 8_000)
        delivery.append(head, graphID: graph)
        var recorded = Data()
        router.promote { recorded.append($0) }
        let middle = Data(repeating: 2, count: 320_000)
        let tail = Data(repeating: 3, count: 4_000)
        delivery.append(middle, graphID: graph)
        delivery.append(tail, graphID: graph)
        XCTAssertEqual(delivery.stop(), head.count + middle.count + tail.count)
        let wav = VoxDictationEngine.wav(recorded)
        XCTAssertEqual(Data(wav.dropFirst(44)), head + middle + tail)
    }

    func testNoAudioUntilNonemptyPCMAndStaleGraphsCannotDeliver() {
        let delivery = CaptureAudioDelivery()
        var recorded = Data()
        let oldGraph = delivery.replaceGraph()
        delivery.begin { recorded.append($0) }
        XCTAssertFalse(delivery.hasAudio)
        delivery.append(Data(), graphID: oldGraph)
        XCTAssertFalse(delivery.hasAudio)
        let graph = delivery.replaceGraph()
        delivery.append(Data([9]), graphID: oldGraph)
        XCTAssertFalse(delivery.hasAudio)
        delivery.append(Data([1, 2]), graphID: graph)
        XCTAssertTrue(delivery.hasAudio)
        XCTAssertEqual(delivery.stop(), 2)
        delivery.append(Data([3, 4]), graphID: graph)
        XCTAssertEqual(recorded, Data([1, 2]))
        delivery.begin { recorded.append($0) }
        XCTAssertFalse(delivery.hasAudio)
    }

    func testSelectedDefaultMicrophoneUsesDefaultPathWithoutExplicitBinding() {
        XCTAssertNil(AudioCapture.bindingUID(for: nil, defaultUID: "brio"))
        XCTAssertNil(AudioCapture.bindingUID(for: "brio", defaultUID: "brio"))
        XCTAssertEqual(AudioCapture.bindingUID(for: "built-in", defaultUID: "brio"), "built-in")
        XCTAssertEqual(AudioCapture.bindingUID(for: "built-in", defaultUID: nil), "built-in")
    }

    func testConverterRetainsBeginningAndDurationAcrossManyBuffers() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: format, to: AudioCapture.targetFormat))
        var pcm = Data()
        for index in 0..<300 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
            buffer.frameLength = 1_024
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<1_024 { channel[frame] = index < 150 ? 0.25 : -0.25 }
            if let chunk = AudioCapture.convert(buffer, using: converter) { pcm.append(chunk) }
        }
        // Allow only converter priming latency, not seconds of missing audio.
        XCTAssertEqual(Double(pcm.count) / 32_000, 300 * 1_024 / 48_000.0, accuracy: 0.03)
        let samples: [Int16] = stride(from: 0, to: pcm.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8)
        }
        XCTAssertGreaterThan(samples[1_000], 7_000)
        XCTAssertGreaterThan(samples[samples.count / 4], 7_000)
        XCTAssertLessThan(samples[samples.count * 3 / 4], -7_000)
    }
}
