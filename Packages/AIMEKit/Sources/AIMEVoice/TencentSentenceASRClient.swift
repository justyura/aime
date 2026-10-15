import Foundation
import CryptoKit

/// Shared by iOS and macOS. Buffers 16 kHz, signed 16-bit mono PCM until finish().
final class TencentSentenceASRClient: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    private let secretID: String
    private let secretKey: String
    private let session: URLSession
    private let queue = DispatchQueue(label: "com.voxboard.tencent-sentence")
    private var audio = Data()
    private var task: URLSessionDataTask?
    private var started = false
    private var finishing = false
    private var closed = false
    static let maximumAudioBytes = 60 * 16_000 * 2

    init(secretID: String, secretKey: String, session: URLSession = .shared) {
        self.secretID = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.closed else { return }
            self.started = true
            if self.secretID.isEmpty || self.secretKey.isEmpty {
                self.fail("请先在设置中填写腾讯云 SecretId 和 SecretKey")
            }
        }
    }

    func appendAudio(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            guard data.count <= Self.maximumAudioBytes - self.audio.count else {
                self.fail("腾讯云一句话识别最多支持 60 秒，请缩短录音后重试")
                return
            }
            self.audio.append(data)
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.finishing = true
            guard !self.audio.isEmpty else {
                self.close()
                self.onTranscript?("", true)
                return
            }
            do {
                let request = try Self.makeRequest(audio: self.audio,
                    secretID: self.secretID, secretKey: self.secretKey)
                self.audio.removeAll()
                self.task = self.session.dataTask(with: request) { [weak self] data, response, error in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.closed else { return }
                        if let error {
                            self.fail("腾讯云请求失败：\(error.localizedDescription)")
                            return
                        }
                        do {
                            let text = try Self.parseResponse(data ?? Data(),
                                status: (response as? HTTPURLResponse)?.statusCode ?? 0)
                            self.close()
                            self.onTranscript?(text, true)
                        } catch {
                            self.fail(error.localizedDescription)
                        }
                    }
                }
                self.task?.resume()
                self.queue.asyncAfter(deadline: .now() + 18) { [weak self] in
                    guard let self, !self.closed else { return }
                    self.fail("腾讯云识别超时，请重试")
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func cancel() { queue.async { [weak self] in self?.close() } }

    private func close() {
        closed = true
        task?.cancel()
        task = nil
        audio.removeAll()
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        close()
        onError?(message)
    }

    static func makeRequest(audio: Data, secretID: String, secretKey: String,
                            date: Date = Date(), engineModel: String = "16k_zh") throws -> URLRequest {
        guard audio.count <= maximumAudioBytes, audio.count.isMultiple(of: 2) else {
            throw failure("腾讯云音频必须为 60 秒内的 16kHz / 16bit 单声道 PCM")
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "EngSerViceType": engineModel, "SourceType": 1, "VoiceFormat": "pcm",
            "Data": audio.base64EncodedString(), "DataLen": audio.count,
        ], options: [.sortedKeys])
        let host = "asr.tencentcloudapi.com"
        let contentType = "application/json; charset=utf-8"
        let timestamp = String(Int(date.timeIntervalSince1970))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let scope = "\(day)/asr/tc3_request"
        let canonical = "POST\n/\n\ncontent-type:\(contentType)\nhost:\(host)\n\ncontent-type;host\n\(hex(SHA256.hash(data: body)))"
        let toSign = "TC3-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hex(SHA256.hash(data: Data(canonical.utf8))))"
        let dayKey = hmac(Data(("TC3" + secretKey).utf8), day)
        let serviceKey = hmac(dayKey, "asr")
        let signingKey = hmac(serviceKey, "tc3_request")
        let signature = hex(hmac(signingKey, toSign))
        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue("SentenceRecognition", forHTTPHeaderField: "X-TC-Action")
        request.setValue("2019-06-14", forHTTPHeaderField: "X-TC-Version")
        request.setValue(timestamp, forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue("TC3-HMAC-SHA256 Credential=\(secretID)/\(scope), SignedHeaders=content-type;host, Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func parseResponse(_ data: Data, status: Int) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["Response"] as? [String: Any] else {
            throw failure("腾讯云返回内容无法解析（HTTP \(status)）")
        }
        if let error = response["Error"] as? [String: Any] {
            throw failure("腾讯云：\(error["Code"] as? String ?? "Unknown")：\(error["Message"] as? String ?? "请求失败")")
        }
        guard (200..<300).contains(status), let text = response["Result"] as? String else {
            throw failure("腾讯云响应缺少识别结果（HTTP \(status)）")
        }
        return text
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TencentSentenceASR", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func hmac(_ key: Data, _ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
