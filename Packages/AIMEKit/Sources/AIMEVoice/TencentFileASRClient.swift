import Foundation
import CryptoKit
import AVFoundation

/// File flash API uploads original audio, independently of the live dictation session.
struct TencentFileASRClient {
    static let maximumBytes = 100_000_000
    static let formats = ["wav", "mp3", "m4a", "aac"]
    let appID: String
    let secretID: String
    let secretKey: String

    func transcribe(_ url: URL) async throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw Self.error("请选择音频文件") }
        try Self.validate(size: values.fileSize ?? 0, format: url.pathExtension.lowercased())
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 7200 else {
            throw Self.error("录音文件需有有效时长，且不超过 2 小时")
        }
        try Task.checkCancellation()
        let request = try makeRequest(format: url.pathExtension.lowercased(), size: values.fileSize ?? 0)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, fromFile: url)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.error("录音文件上传或识别失败，请检查网络后重试")
        }
        try Task.checkCancellation()
        return try Self.parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func makeRequest(format: String, size: Int, timestamp: Int = Int(Date().timeIntervalSince1970)) throws -> URLRequest {
        try Self.validate(size: size, format: format)
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }),
              !secretID.isEmpty, !secretKey.isEmpty else {
            throw Self.error("请在「识别引擎」中填写腾讯云数字 AppID、SecretId 和 SecretKey")
        }
        let parameters = ["engine_type": "16k_zh_en", "voice_format": format,
                          "secretid": secretID, "timestamp": String(timestamp),
                          "first_channel_only": "1", "speaker_diarization": "0",
                          "convert_num_mode": "1", "word_info": "0"]
        let keys = parameters.keys.sorted()
        let rawQuery = keys.map { "\($0)=\(parameters[$0]!)" }.joined(separator: "&")
        let path = "asr.cloud.tencent.com/asr/flash/v1/\(appID)"
        let signature = Data(HMAC<Insecure.SHA1>.authenticationCode(
            for: Data("POST\(path)?\(rawQuery)".utf8), using: SymmetricKey(data: Data(secretKey.utf8))
        )).base64EncodedString()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = keys.map { "\($0)=\(parameters[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://\(path)?\(query)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        request.setValue("asr.cloud.tencent.com", forHTTPHeaderField: "Host")
        request.setValue(signature, forHTTPHeaderField: "Authorization")
        return request
    }

    static func validate(size: Int, format: String) throws {
        guard formats.contains(format) else { throw error("支持 WAV、MP3、M4A 和 AAC 音频") }
        guard size > 0, size <= maximumBytes else { throw error("音频不能为空，且大小不能超过 100 MB") }
    }

    static func parse(_ data: Data, status: Int) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int else { throw error("腾讯云返回内容无法解析（HTTP \(status)）") }
        guard code == 0, (200..<300).contains(status) else {
            throw error("腾讯云错误 \(code)：\(json["message"] as? String ?? "HTTP \(status)")")
        }
        guard let results = json["flash_result"] as? [[String: Any]],
              results.allSatisfy({ $0["text"] is String }) else { throw error("腾讯云响应缺少转写结果") }
        return results.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "TencentFileASR", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
