import XCTest
@testable import AIMEVoice

final class TencentFileASRTests: XCTestCase {
    func testFileRequestSignatureMatchesPythonVector() throws {
        let client = TencentFileASRClient(appID: "12345", secretID: "test-id", secretKey: "test-key")
        let request = try client.makeRequest(format: "wav", size: 6400, timestamp: 1599140162)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "1E8nOfYNGj2B1xrma+cTgqXXbzA=")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "6400")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.httpBody)
        XCTAssertTrue(request.url!.path.contains("/asr/flash/v1/12345"))
    }
    func testFileValidationAndResponses() throws {
        XCTAssertNoThrow(try TencentFileASRClient.validate(size: 100_000_000, format: "m4a"))
        for size in [0, -1, 100_000_001] {
            XCTAssertThrowsError(try TencentFileASRClient.validate(size: size, format: "wav"))
        }
        XCTAssertThrowsError(try TencentFileASRClient.validate(size: 1, format: "exe"))
        let success = Data(#"{"code":0,"flash_result":[{"text":"你好，Mac。"}]}"#.utf8)
        XCTAssertEqual(try TencentFileASRClient.parse(success, status: 200), "你好，Mac。")
        XCTAssertThrowsError(try TencentFileASRClient.parse(success, status: 500))
        XCTAssertThrowsError(try TencentFileASRClient.parse(Data(#"{"code":4003,"message":"服务未开通"}"#.utf8), status: 200))
        XCTAssertThrowsError(try TencentFileASRClient.parse(Data(#"{"code":0}"#.utf8), status: 200))
    }
}
