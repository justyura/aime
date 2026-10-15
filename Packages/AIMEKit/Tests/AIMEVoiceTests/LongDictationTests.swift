import XCTest
import AppKit
@testable import AIMEVoice

final class LongDictationTests: XCTestCase {
    func testTwoMinuteTencentRecordingKeepsAllAudioInOrder() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SentenceStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        SentenceStub.sizes = []
        let client = TencentSegmentedASRClient(secretID: "test", secretKey: "test", model: "16k_en", session: session)
        let done = expectation(description: "all segments")
        client.onError = { XCTFail($0); done.fulfill() }
        client.onTranscript = { text, final in
            if final { XCTAssertEqual(text, "part1 part2 part3"); done.fulfill() }
        }
        client.start()
        for _ in 0..<125 { client.appendAudio(Data(count: 32_000)) }
        client.finish()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(SentenceStub.sizes, [50 * 32_000, 50 * 32_000, 25 * 32_000])
    }

    func testElevenLabsDraftCorrectionsNeverReachEditor() throws {
        let client = ElevenLabsRealtimeASRClient(endpoint: "wss://example.com", apiKey: "test", model: "test")
        var inserted: [String] = []
        var previews: [String] = []
        client.onTranscript = { text, final in XCTAssertFalse(final); inserted.append(text) }
        client.onPreview = { previews.append($0) }
        func event(_ type: String, _ text: String) throws {
            client.handleMessage(try JSONSerialization.data(withJSONObject: ["message_type": type, "text": text]))
        }
        try event("partial_transcript", "hello wor")
        try event("partial_transcript", "hello world")
        XCTAssertTrue(inserted.isEmpty)
        try event("committed_transcript", "hello world")
        try event("committed_transcript_with_timestamps", "hello world")
        try event("partial_transcript", "你好")
        try event("committed_transcript", "你好")
        try event("committed_transcript", "你好")
        XCTAssertEqual(inserted, ["hello world", "hello world你好", "hello world你好你好"])
        XCTAssertEqual(previews.count, 3)
    }
}

private final class SentenceStub: URLProtocol {
    static var sizes: [Int] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        Self.sizes.append(object["DataLen"] as! Int)
        XCTAssertEqual(object["EngSerViceType"] as? String, "16k_en")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"Response\":{\"Result\":\"part\(Self.sizes.count)\"}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
