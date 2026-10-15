import Foundation
import CryptoKit

protocol TencentRealtimeSocket: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func stop()
}

extension URLSessionWebSocketTask: TencentRealtimeSocket {
    func stop() { cancel(with: .normalClosure, reason: nil) }
}

/// Tencent WebSocket ASR: 16 kHz / 16-bit mono PCM, paced at 200 ms per packet.
final class TencentRealtimeASRClient: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    private let appID: String
    private let secretID: String
    private let secretKey: String
    private let queue = DispatchQueue(label: "com.voxboard.tencent-realtime")
    private let socketFactory: (URLRequest) -> TencentRealtimeSocket
    private var task: TencentRealtimeSocket?
    private var audio = Data()
    private var started = false
    private var ready = false
    private var finishing = false
    private var endSent = false
    private var closed = false
    private var sending = false
    private var scheduled = false
    private var nextSend = DispatchTime.now()
    private var transcript = TencentRealtimeTranscript()

    init(appID: String, secretID: String, secretKey: String,
         socketFactory: @escaping (URLRequest) -> TencentRealtimeSocket = {
             URLSession.shared.webSocketTask(with: $0)
         }) {
        self.socketFactory = socketFactory
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretID = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.closed else { return }
            self.started = true
            do {
                let url = try Self.signedURL(appID: self.appID, secretID: self.secretID,
                                             secretKey: self.secretKey)
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                let task = self.socketFactory(request)
                self.task = task
                task.resume()
                self.receive()
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, !self.closed, !self.ready else { return }
                    self.fail("腾讯云实时连接超时")
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func appendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.started, !self.closed, !self.finishing else { return }
            // Bound connection/backpressure buffering; never burst buffered PCM faster than real time.
            guard data.count <= 16_000 * 2 * 10 - self.audio.count else {
                self.fail("腾讯云网络发送过慢，请重试")
                return
            }
            self.audio.append(data)
            self.pump()
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, self.started, !self.closed, !self.finishing else { return }
            self.finishing = true
            self.pump()
            self.queue.asyncAfter(deadline: .now() + 18) { [weak self] in
                guard let self, !self.closed else { return }
                self.fail("腾讯云实时识别收尾超时")
            }
        }
    }

    func cancel() { queue.async { [weak self] in self?.close() } }

    private func pump() {
        guard ready, !closed, !sending, !scheduled, !endSent, let task else { return }
        guard audio.count >= 6_400 || finishing else { return }
        let now = DispatchTime.now()
        if nextSend > now {
            scheduled = true
            queue.asyncAfter(deadline: nextSend) { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.pump()
            }
            return
        }
        let message: URLSessionWebSocketTask.Message
        if audio.isEmpty {
            endSent = true
            message = .string(#"{"type":"end"}"#)
        } else {
            let count = min(6_400, audio.count)
            message = .data(Data(audio.prefix(count)))
            audio.removeFirst(count)
            nextSend = now + Double(count) / 32_000
        }
        sending = true
        task.send(message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.sending = false
                if error != nil {
                    // URLSession errors may contain the signed URL; do not surface credentials.
                    self.fail("腾讯云音频发送失败，请检查网络")
                } else {
                    self.pump()
                }
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .failure:
                    self.fail("腾讯云实时连接中断，请检查 AppID、密钥和网络")
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default:
                        self.fail("腾讯云返回未知消息格式")
                        return
                    }
                    do {
                        let event = try self.transcript.consume(data)
                        if !self.ready {
                            self.ready = true
                            self.nextSend = .now()
                            self.pump()
                        }
                        if event.isFinal {
                            self.close()
                            self.onTranscript?(event.text, true)
                        } else if event.changed {
                            self.onTranscript?(event.text, false)
                        }
                        if !self.closed { self.receive() }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        close()
        onError?(message)
    }

    private func close() {
        closed = true
        task?.stop()
        task = nil
        audio.removeAll()
    }

    static func signedURL(appID: String, secretID: String, secretKey: String,
                          timestamp: Int = Int(Date().timeIntervalSince1970),
                          nonce: Int = Int.random(in: 1...999_999_999),
                          voiceID: String = UUID().uuidString) throws -> URL {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }),
              !secretID.isEmpty, !secretKey.isEmpty else {
            throw tencentRealtimeError("请在设置中填写腾讯云数字 AppID、SecretId 和 SecretKey")
        }
        let parameters = [
            "engine_model_type": "16k_zh_en", "expired": String(timestamp + 3600),
            "needvad": "1", "nonce": String(nonce), "secretid": secretID,
            "timestamp": String(timestamp), "voice_format": "1", "voice_id": voiceID,
        ]
        let keys = parameters.keys.sorted()
        let rawQuery = keys.map { "\($0)=\(parameters[$0]!)" }.joined(separator: "&")
        let path = "asr.cloud.tencent.com/asr/v2/\(appID)"
        let signature = Data(HMAC<Insecure.SHA1>.authenticationCode(
            for: Data("\(path)?\(rawQuery)".utf8), using: SymmetricKey(data: Data(secretKey.utf8))
        )).base64EncodedString()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed)! }
        let query = keys.map { "\($0)=\(encode(parameters[$0]!))" }.joined(separator: "&")
        guard let url = URL(string: "wss://\(path)?\(query)&signature=\(encode(signature))") else {
            throw tencentRealtimeError("腾讯云实时请求地址无效")
        }
        return url
    }
}

/// Results are per sentence, not cumulative. Replace by index to avoid duplicated commits.
struct TencentRealtimeTranscript {
    private var segments: [Int: String] = [:]
    private var committed: Set<Int> = []
    private(set) var text = ""

    mutating func consume(_ data: Data) throws -> (text: String, changed: Bool, isFinal: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int else {
            throw tencentRealtimeError("腾讯云实时响应无法解析")
        }
        guard code == 0 else {
            throw tencentRealtimeError("腾讯云实时错误 \(code)：\(json["message"] as? String ?? "请求失败")")
        }
        let previous = text
        if let result = json["result"] as? [String: Any] {
            guard let index = result["index"] as? Int,
                  let slice = result["slice_type"] as? Int, (0...2).contains(slice),
                  let value = result["voice_text_str"] as? String else {
                throw tencentRealtimeError("腾讯云实时结果缺少分句信息")
            }
            if !committed.contains(index) {
                segments[index] = value
                if slice == 2 { committed.insert(index) }
            }
            text = segments.keys.sorted().reduce("") {
                #if os(iOS)
                AudioRecorder.joinTranscriptSegments($0, segments[$1]!)
                #else
                joinTranscriptSegments($0, segments[$1]!)
                #endif
            }
        }
        return (text, previous != text, (json["final"] as? Int) == 1)
    }
}

private func tencentRealtimeError(_ message: String) -> NSError {
    NSError(domain: "TencentRealtimeASR", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
