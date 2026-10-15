import XCTest
@testable import AIMEVoice

final class TencentRealtimeASRTests: XCTestCase {
    func testSignatureAndEncoding() throws {
        let url = try TencentRealtimeASRClient.signedURL(appID: "12345", secretID: "test-id",
            secretKey: "test-key", timestamp: 1599140162, nonce: 123, voiceID: "test-voice")
        XCTAssertTrue(url.absoluteString.hasSuffix("signature=vP3VjDNE3nKmSYzp6DKOp%2BtZO3E%3D"))
        XCTAssertTrue(url.absoluteString.contains("engine_model_type=16k_zh_en"))
        XCTAssertThrowsError(try TencentRealtimeASRClient.signedURL(appID: "", secretID: "id", secretKey: "key"))
        XCTAssertThrowsError(try TencentRealtimeASRClient.signedURL(appID: "../1", secretID: "id", secretKey: "key"))
        let second = try TencentRealtimeASRClient.signedURL(appID: "12345", secretID: "id", secretKey: "key")
        let third = try TencentRealtimeASRClient.signedURL(appID: "12345", secretID: "id", secretKey: "key")
        XCTAssertNotEqual(second, third)
    }

    func testPartialCorrectionMultipleSentencesAndFinal() throws {
        var transcript = TencentRealtimeTranscript()
        func packet(_ index: Int, _ slice: Int, _ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["code": 0,
                "result": ["index": index, "slice_type": slice, "voice_text_str": text]])
        }
        XCTAssertFalse(try transcript.consume(Data(#"{"code":0}"#.utf8)).changed)
        XCTAssertEqual(try transcript.consume(packet(0, 1, "你号")).text, "你号")
        XCTAssertEqual(try transcript.consume(packet(0, 2, "你好。")).text, "你好。")
        XCTAssertFalse(try transcript.consume(packet(0, 2, "你好。")).changed)
        XCTAssertEqual(try transcript.consume(packet(1, 1, "hello")).text, "你好。hello")
        XCTAssertEqual(try transcript.consume(packet(0, 1, "迟到")).text, "你好。hello")
        XCTAssertEqual(try transcript.consume(packet(1, 2, "hello world")).text, "你好。hello world")
        let final = try transcript.consume(Data(#"{"code":0,"final":1}"#.utf8))
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.text, "你好。hello world")
        XCTAssertThrowsError(try transcript.consume(Data(#"{"code":4001,"message":"invalid signature"}"#.utf8)))
        XCTAssertThrowsError(try transcript.consume(Data("invalid".utf8)))
    }

    func testHandshakePacingTailAndEndOrder() {
        let socket = MockTencentSocket()
        let receiving = expectation(description: "waiting for handshake")
        socket.onFirstReceive = { receiving.fulfill() }
        let final = expectation(description: "final")
        let client = TencentRealtimeASRClient(appID: "12345", secretID: "id", secretKey: "key",
                                             socketFactory: { _ in socket })
        client.onError = { XCTFail($0) }
        client.onTranscript = { _, done in if done { final.fulfill() } }
        client.start()
        let audio = Data(repeating: 7, count: 13_000)
        client.appendAudio(audio)
        client.finish()
        client.finish()
        wait(for: [receiving], timeout: 2)
        XCTAssertEqual(socket.snapshot().count, 0)
        socket.deliver(#"{"code":0}"#)
        wait(for: [final], timeout: 3)
        let sent = socket.snapshot()
        XCTAssertEqual(sent.count, 4)
        var recovered = Data()
        for (index, record) in sent.enumerated() {
            switch record.0 {
            case .data(let bytes):
                recovered.append(bytes)
                XCTAssertEqual(bytes.count, index < 2 ? 6400 : 200)
            case .string(let string):
                XCTAssertEqual(index, 3)
                XCTAssertEqual(string, #"{"type":"end"}"#)
            @unknown default: XCTFail("Unknown packet")
            }
        }
        XCTAssertEqual(recovered, audio)
        XCTAssertGreaterThanOrEqual(sent[1].1 - sent[0].1, 0.18)
        XCTAssertGreaterThanOrEqual(sent[2].1 - sent[1].1, 0.18)
    }

    func testCancelBeforeHandshakeDropsQueuedAudio() {
        let socket = MockTencentSocket()
        let stopped = expectation(description: "cancelled")
        socket.onStop = { stopped.fulfill() }
        let client = TencentRealtimeASRClient(appID: "12345", secretID: "id", secretKey: "key",
                                             socketFactory: { _ in socket })
        client.onError = { XCTFail($0) }
        client.onTranscript = { _, _ in XCTFail("Cancelled callback") }
        client.start()
        client.appendAudio(Data(count: 6400))
        client.cancel()
        client.finish()
        wait(for: [stopped], timeout: 2)
        XCTAssertTrue(socket.snapshot().isEmpty)
    }
}

private final class MockTencentSocket: TencentRealtimeSocket {
    var onFirstReceive: (() -> Void)?
    var onStop: (() -> Void)?
    private let lock = NSLock()
    private var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var records: [(URLSessionWebSocketTask.Message, TimeInterval)] = []
    func resume() {}
    func stop() { onStop?() }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.lock()
        receiver = completionHandler
        let first = onFirstReceive
        onFirstReceive = nil
        lock.unlock()
        first?()
    }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        records.append((message, ProcessInfo.processInfo.systemUptime))
        lock.unlock()
        completionHandler(nil)
        if case .string = message { deliver(#"{"code":0,"final":1}"#) }
    }
    func deliver(_ text: String) {
        lock.lock()
        let callback = receiver
        receiver = nil
        lock.unlock()
        callback?(.success(.string(text)))
    }
    func snapshot() -> [(URLSessionWebSocketTask.Message, TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
