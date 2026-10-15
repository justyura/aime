import XCTest
@testable import AIMEVoice

final class ElevenLabsTranscriptionTests: XCTestCase {
    func testRequestUploadsRawPCMToScribeV2() throws {
        let pcm = Data([1, 2, 3, 4])
        let request = ElevenLabsTranscriptionClient.makeRequest(
            pcm: pcm, apiKey: "key", model: elevenLabsBatchModel
        )
        XCTAssertEqual(request.url, elevenLabsTranscriptionEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "key")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        XCTAssertTrue(text.contains("name=\"file_format\"\r\n\r\npcm_s16le_16\r\n"))
        XCTAssertTrue(text.contains("name=\"tag_audio_events\"\r\n\r\nfalse\r\n"))
        let fileTail = Data("\r\n\r\n".utf8) + pcm + Data("\r\n--\(boundary)--\r\n".utf8)
        XCTAssertNotNil(body.range(of: fileTail))
    }

    func testParsesTranscriptAndBothErrorShapes() {
        func parse(_ json: String, _ status: Int) -> Result<String, ElevenLabsTranscriptionClient.ResponseError> {
            ElevenLabsTranscriptionClient.parseResponse(Data(json.utf8), status: status)
        }
        XCTAssertEqual(try parse(#"{"language_code":"zh","text":" 你好 world \n"}"#, 200).get(), "你好 world")
        XCTAssertEqual(
            parse(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, 401),
            .failure(.init(message: "ElevenLabs：Invalid API key"))
        )
        XCTAssertEqual(
            parse(#"{"detail":[{"loc":["body","model_id"],"msg":"Field required","type":"missing"}]}"#, 422),
            .failure(.init(message: "ElevenLabs：Field required"))
        )
        XCTAssertEqual(parse("Bad Gateway", 502), .failure(.init(message: "ElevenLabs：HTTP 502")))
    }

    func testRecordingShorterThanMinimumCompletesEmptyWithoutUpload() {
        let client = ElevenLabsTranscriptionClient(apiKey: "key", model: elevenLabsBatchModel)
        let done = expectation(description: "final transcript")
        client.onTranscript = { text, isFinal in
            XCTAssertEqual(text, "")
            XCTAssertTrue(isFinal)
            done.fulfill()
        }
        client.onError = { XCTFail($0) }
        client.start()
        client.appendAudio(Data(repeating: 0, count: 1_000))
        client.finish()
        wait(for: [done], timeout: 1)
    }

    func testMissingKeyFailsBeforeRecordingIsUploaded() {
        let client = ElevenLabsTranscriptionClient(apiKey: "", model: elevenLabsBatchModel)
        let failed = expectation(description: "missing key")
        client.onError = { message in
            XCTAssertTrue(message.contains("API Key"))
            failed.fulfill()
        }
        client.start()
        wait(for: [failed], timeout: 1)
    }
}
