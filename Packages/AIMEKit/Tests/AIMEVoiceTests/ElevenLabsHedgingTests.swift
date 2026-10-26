@testable import AIMEVoice
import Foundation
import XCTest

/// First request stalls (TLS up, no answer — as seen through a proxy); later ones answer.
final class StallingFirstRequest: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let number = Self.requests
        Self.lock.unlock()
        guard number > 1 else { return } // never answers
        let body = Data(#"{"text":"你好世界"}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ElevenLabsHedgingTests: XCTestCase {
    func testStalledRequestIsOvertakenByHedgedCopy() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingFirstRequest.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        StallingFirstRequest.requests = 0
        let client = ElevenLabsTranscriptionClient(apiKey: "test", model: "scribe_v2", session: session, hedgeDelay: 0.2)
        let done = expectation(description: "final")
        client.onError = { XCTFail($0); done.fulfill() }
        client.onTranscript = { text, final in
            XCTAssertTrue(final)
            XCTAssertEqual(text, "你好世界")
            done.fulfill()
        }
        client.start()
        client.appendAudio(Data(count: 32_000))
        client.finish()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(StallingFirstRequest.requests, 2)
    }

    func testHedgeDelayGrowsWithRecordingLength() {
        XCTAssertEqual(ElevenLabsTranscriptionClient.hedgeDelay(audioBytes: 32_000), 3.125, accuracy: 0.001)
        XCTAssertEqual(ElevenLabsTranscriptionClient.hedgeDelay(audioBytes: 80 * 32_000), 13, accuracy: 0.001)
        XCTAssertEqual(ElevenLabsTranscriptionClient.hedgeDelay(audioBytes: 600 * 32_000), 30)
    }
}
