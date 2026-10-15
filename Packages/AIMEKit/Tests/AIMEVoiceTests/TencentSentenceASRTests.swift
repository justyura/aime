import XCTest
@testable import AIMEVoice

final class TencentSentenceASRTests: XCTestCase {
    func testSigningAgainstIndependentPythonVector() throws {
        let request = try TencentSentenceASRClient.makeRequest(audio: Data([0, 0]),
            secretID: "test-id", secretKey: "test-key", date: Date(timeIntervalSince1970: 1599140162))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
            "TC3-HMAC-SHA256 Credential=test-id/2020-09-03/asr/tc3_request, SignedHeaders=content-type;host, Signature=94a4bca14e025f2ec0d92e8d856ad162588a9317a8bf187148906a331473b295")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["DataLen"] as? Int, 2)
        XCTAssertEqual(body["Data"] as? String, "AAA=")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "SentenceRecognition")
    }

    func testAudioLimits() throws {
        _ = try TencentSentenceASRClient.makeRequest(
            audio: Data(count: TencentSentenceASRClient.maximumAudioBytes), secretID: "id", secretKey: "key")
        for count in [1, TencentSentenceASRClient.maximumAudioBytes + 2] {
            XCTAssertThrowsError(try TencentSentenceASRClient.makeRequest(
                audio: Data(count: count), secretID: "id", secretKey: "key"))
        }
    }

    func testResponses() throws {
        XCTAssertEqual(try TencentSentenceASRClient.parseResponse(
            Data(#"{"Response":{"Result":"你好"}}"#.utf8), status: 200), "你好")
        for (body, status) in [
            (#"{"Response":{"Error":{"Code":"AuthFailure","Message":"bad key"}}}"#, 200),
            (#"{"Response":{}}"#, 200), ("bad gateway", 502),
            (#"{"Response":{"Result":"ignored"}}"#, 500)
        ] {
            XCTAssertThrowsError(try TencentSentenceASRClient.parseResponse(Data(body.utf8), status: status))
        }
    }

    func testMissingCredentialsAndOverflowReportOnce() {
        for credentialsMissing in [true, false] {
            let error = expectation(description: "error")
            error.assertForOverFulfill = true
            let client = TencentSentenceASRClient(secretID: credentialsMissing ? "" : "id", secretKey: "key")
            client.onError = { _ in error.fulfill() }
            client.onTranscript = { _, _ in XCTFail("Unexpected transcript") }
            client.start()
            client.appendAudio(Data(count: TencentSentenceASRClient.maximumAudioBytes + 2))
            client.finish()
            wait(for: [error], timeout: 2)
            client.cancel()
        }
    }

    func testCancelSuppressesCallbacks() {
        let callback = expectation(description: "no callback")
        callback.isInverted = true
        let client = TencentSentenceASRClient(secretID: "id", secretKey: "key")
        client.onError = { _ in callback.fulfill() }
        client.onTranscript = { _, _ in callback.fulfill() }
        client.start()
        client.cancel()
        client.appendAudio(Data([0, 0]))
        client.finish()
        wait(for: [callback], timeout: 0.1)
    }
}
