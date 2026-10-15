import XCTest
@testable import AIMEVoice

final class VoxAPIClientTests: XCTestCase {
    func testStorageUploadPreservesSignedURLAndUsesStreamWithoutContentType() throws {
        let file = URL(fileURLWithPath: #filePath)
        let url = URL(string: "https://example.com/audio?signature=a%2Bb%3D")!
        let request = try VoxAPIClient.storageUploadRequest(fileURL: file, uploadURL: url)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotNil(request.httpBodyStream)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(try Data(contentsOf: file).count))
    }

    func testStorageErrorIncludesOSSDiagnosticsButNotSigningDetails() {
        let xml = "<Error><Code>SignatureDoesNotMatch</Code><Message>Bad &amp; invalid signature</Message><RequestId>test-id</RequestId><StringToSign>private-signing-details</StringToSign></Error>"
        let message = VoxAPIClient.storageError(data: Data(xml.utf8), status: 403)
        XCTAssertTrue(message.contains("SignatureDoesNotMatch"))
        XCTAssertTrue(message.contains("Bad & invalid signature"))
        XCTAssertTrue(message.contains("test-id"))
        XCTAssertFalse(message.contains("private-signing-details"))
        XCTAssertEqual(VoxAPIClient.storageError(data: Data("not XML".utf8), status: 500),
                       "对象存储上传失败（HTTP 500）")
    }
    func testDictationWAVContainsPCMAndMono16KHeader() {
        let pcm = Data([0, 0, 255, 127])
        let wav = VoxDictationEngine.wav(pcm)
        XCTAssertEqual(wav.count, 48)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(Array(wav[22..<28]), [1, 0, 128, 62, 0, 0])
        XCTAssertEqual(Array(wav[34..<36]), [16, 0])
        XCTAssertEqual(wav.suffix(4), pcm)
    }
    func testLoginFormPreservesSpecialCharacters() throws {
        let values = ["email": "name+vox@example.com", "password": "a+b &=%中文"]
        let data = try XCTUnwrap(VoxAPIClient.formData(values))
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Match application/x-www-form-urlencoded decoding, including Go PostForm.
        var decoded: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 2)
            decoded[String(parts[0])] = String(parts[1])
                .replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        XCTAssertEqual(decoded, values)
    }
}

final class VoxHistoryTests: XCTestCase {
    func testTranscriptParsesSegmentsAndFallsBackToPlainText() {
        let raw = #"{"text":" 你好 world ","segments":[{"start_ms":0,"end_ms":1200,"text":" 你好 "},{"start_ms":1200,"end_ms":900,"text":"bad"},{"start_ms":1200,"end_ms":2000,"text":""},{"start_ms":1200,"end_ms":2400,"text":"world"}]}"#
        let transcript = VoxAPIClient.Transcript.parse(raw)
        XCTAssertEqual(transcript.text, "你好 world")
        XCTAssertEqual(transcript.segments, [.init(startMS: 0, endMS: 1200, text: "你好"),
                                             .init(startMS: 1200, endMS: 2400, text: "world")])
        XCTAssertEqual(VoxAPIClient.Transcript.parse(" plain text\n"), .init(text: "plain text", segments: []))
        let untitled = VoxAPIClient.Transcript.parse(#"{"text":"","segments":[{"start_ms":0,"end_ms":5,"text":"a"},{"start_ms":5,"end_ms":9,"text":"b"}]}"#)
        XCTAssertEqual(untitled.text, "a b")
    }

    func testTaskInfoReadsProtobufJSONFromGin() throws {
        let task: [String: Any] = ["task_id": "t1", "input_file_id": "in", "status": "completed",
                                   "created_at": ["seconds": 1_700_000_000, "nanos": 500_000_000]]
        let info = try XCTUnwrap(VoxAPIClient.taskInfo(from: task))
        XCTAssertEqual(info.outputFileID, "")
        XCTAssertEqual(info.createdAt, Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertNil(VoxAPIClient.taskInfo(from: ["status": "completed"]))
    }

}
