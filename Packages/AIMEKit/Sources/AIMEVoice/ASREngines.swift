//
//  ASREngines.swift
//  VoxBoardMac
//
//  流式 ASR 引擎,移植自 iOS 主工程 AudioRecorder.swift(去掉 UIKit 依赖)。
//  喂 16k/16bit/单声道 PCM,回调"本段听写"的累计文本(text 为整段累计)。
//

import Foundation
import zlib

// Credentials are never bundled: VoiceSettings reads them from the user's preferences.
let volcRealtimeEndpoint = URL(
    string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
)!
let volcRealtimeResourceId = "volc.bigasr.sauc.duration"

let elevenLabsModel = "scribe_v2_realtime"
let elevenLabsRealtimeEndpoint = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
let elevenLabsBatchModel = "scribe_v2"
let elevenLabsTranscriptionEndpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

/// 可切换的流式 ASR 引擎接口。喂 16k/16bit/单声道 PCM,回调增量与最终文本。
protocol RealtimeASREngine: AnyObject {
    var onTranscript: ((String, Bool) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start()
    func appendAudio(_ data: Data)
    func finish()
    func cancel()
}

/// ASR 常把停顿写成 "......" / "……";ElevenLabs 还会输出 "--" / "——"。
/// 句首句尾直接丢掉,句中收敛为一个逗号。
func normalizeTranscriptPunctuation(_ text: String) -> String {
    let pauseMarker = #"(?:\.{2,}|…+|-{2,}|–{2,}|—{2,})"#
    var result = text.replacingOccurrences(
        of: #"^\s*"# + pauseMarker + #"\s*"#,
        with: "",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"\s*"# + pauseMarker + #"\s*$"#,
        with: "",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"\s*"# + pauseMarker + #"\s*"#,
        with: "，",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"，{2,}"#,
        with: "，",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"，(?=[。！？!?])"#,
        with: "",
        options: .regularExpression
    )
    return result
}

/// 多 segment 合成一条累计转写。中文直接相连,英文边界按需补一个空格。
func joinTranscriptSegments(_ prefix: String, _ segment: String) -> String {
    guard !prefix.isEmpty else { return segment }
    guard !segment.isEmpty else { return prefix }
    guard let left = prefix.last, let right = segment.first,
          !left.isWhitespace, !right.isWhitespace else {
        return prefix + segment
    }
    let rightStartsASCIIWord = right.isASCII && (right.isLetter || right.isNumber)
    let asciiOpeningPunctuation: Set<Character> = ["(", "[", "{", "\"", "'"]
    let leftAllowsSpace = left.isASCII && !asciiOpeningPunctuation.contains(left)
    return prefix + (rightStartsASCIIWord && leftAllowsSpace ? " " : "") + segment
}

/// 火山引擎大模型流式语音识别二进制 WebSocket 客户端。
/// 协议要求的 Gzip 压缩运行在独立网络队列,不占用实时音频线程。
final class DoubaoRealtimeASRClient: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private static let audioChunkBytes = 6_400 // 16kHz * 16bit * 200ms

    private let endpoint: URL
    private let appKey: String
    private let accessKey: String
    private let resourceID: String
    private let queue = DispatchQueue(label: "com.wentao.voxboardmac.doubao-realtime")

    private var task: URLSessionWebSocketTask?
    private var pendingPackets: [Data] = []
    private var isSending = false
    private var audioRemainder = Data()
    private var nextSequence: Int32 = 2
    private var started = false
    private var finishing = false
    private var closed = false
    private var latestText = ""

    init(endpoint: URL, appKey: String, accessKey: String, resourceID: String) {
        self.endpoint = endpoint
        self.appKey = appKey
        self.accessKey = accessKey
        self.resourceID = resourceID
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.closed else { return }
            self.started = true

            var request = URLRequest(url: self.endpoint)
            request.timeoutInterval = 15
            request.setValue(self.appKey, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(self.accessKey, forHTTPHeaderField: "X-Api-Access-Key")
            request.setValue(self.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
            request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            self.enqueue(self.configurationPacket())
            self.receiveNextMessage()
        }
    }

    func appendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.audioRemainder.append(data)
            while self.audioRemainder.count >= Self.audioChunkBytes {
                let chunk = self.audioRemainder.prefix(Self.audioChunkBytes)
                self.audioRemainder.removeFirst(Self.audioChunkBytes)
                self.enqueue(self.audioPacket(Data(chunk), isLast: false))
            }
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.finishing = true
            let tail = self.audioRemainder
            self.audioRemainder.removeAll(keepingCapacity: false)
            self.enqueue(self.audioPacket(tail, isLast: true))

            // 偶发收不到服务端最后一个"负序号"包时,不能一直等。
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.closed else { return }
                self.complete(with: self.latestText)
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.close(code: .goingAway)
        }
    }

    private func configurationPacket() -> Data {
        let body: [String: Any] = [
            "user": ["uid": appKey],
            "audio": [
                // 流式发的是裸 PCM(无 RIFF 头),必须声明 pcm。
                "format": "pcm",
                "codec": "raw",
                "rate": 16_000,
                "bits": 16,
                "channel": 1,
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "show_utterances": true,
                "enable_nonstream": false,
            ],
        ]
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return packet(
            messageType: 0x01,
            flags: 0x01,
            serialization: 0x01,
            sequence: 1,
            payload: payload
        )
    }

    private func audioPacket(_ audio: Data, isLast: Bool) -> Data {
        let sequence = nextSequence
        nextSequence += 1
        return packet(
            messageType: 0x02,
            flags: isLast ? 0x03 : 0x01,
            serialization: 0x00,
            sequence: isLast ? -sequence : sequence,
            payload: audio
        )
    }

    private func packet(
        messageType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        sequence: Int32,
        payload: Data
    ) -> Data {
        let compressedPayload = Gzip.compress(payload)
        let wirePayload = compressedPayload ?? payload
        let compression: UInt8 = compressedPayload == nil ? 0x00 : 0x01
        var data = Data([
            0x11, // protocol version 1, header length 1 * 4 bytes
            (messageType << 4) | flags,
            (serialization << 4) | compression,
            0x00,
        ])
        data.appendInt32BigEndian(sequence)
        data.appendUInt32BigEndian(UInt32(wirePayload.count))
        data.append(wirePayload)
        return data
    }

    private func enqueue(_ packet: Data) {
        pendingPackets.append(packet)
        sendNextPacketIfNeeded()
    }

    private func sendNextPacketIfNeeded() {
        guard !isSending, !pendingPackets.isEmpty, !closed, let task else { return }
        isSending = true
        let packet = pendingPackets.removeFirst()
        task.send(.data(packet)) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.isSending = false
                if let error {
                    self.fail("发送音频失败：\(error.localizedDescription)")
                } else {
                    self.sendNextPacketIfNeeded()
                }
            }
        }
    }

    private func receiveNextMessage() {
        guard !closed, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .success(.data(let data)):
                    self.handleResponse(data)
                case .success(.string(let string)):
                    self.handleJSONPayload(Data(string.utf8), isLast: false)
                case .failure(let error):
                    self.fail("连接中断：\(error.localizedDescription)")
                @unknown default:
                    self.fail("收到未知的 WebSocket 消息")
                }
                if !self.closed {
                    self.receiveNextMessage()
                }
            }
        }
    }

    private func handleResponse(_ data: Data) {
        guard data.count >= 4 else {
            fail("服务端响应过短")
            return
        }

        let headerSize = Int(data[0] & 0x0F) * 4
        let messageType = data[1] >> 4
        let flags = data[1] & 0x0F
        let compression = data[2] & 0x0F
        guard headerSize >= 4, data.count >= headerSize else {
            fail("服务端响应头无效")
            return
        }

        var offset = headerSize
        if flags & 0x01 != 0 {
            guard data.readInt32BigEndian(at: &offset) != nil else {
                fail("服务端响应缺少序号")
                return
            }
        }
        if flags & 0x04 != 0 {
            guard data.readInt32BigEndian(at: &offset) != nil else {
                fail("服务端响应缺少事件号")
                return
            }
        }

        if messageType == 0x0F {
            let code = data.readInt32BigEndian(at: &offset) ?? -1
            let errorPayload = readSizedPayload(data, offset: &offset)
                .flatMap { compression == 0x01 ? Gzip.decompress($0) : $0 }
            let message = errorPayload
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            fail("服务端错误 \(code)：\(message)")
            return
        }

        // 0x09 是完整结果;其余 ACK 消息不带识别文本。
        guard messageType == 0x09,
              let payload = readSizedPayload(data, offset: &offset) else { return }
        let jsonPayload: Data
        if compression == 0x01 {
            guard let decompressed = Gzip.decompress(payload) else {
                fail("服务端 Gzip 响应解压失败")
                return
            }
            jsonPayload = decompressed
        } else if compression == 0x00 {
            jsonPayload = payload
        } else {
            fail("服务端返回了不支持的压缩格式")
            return
        }
        handleJSONPayload(jsonPayload, isLast: flags & 0x02 != 0)
    }

    private func readSizedPayload(_ data: Data, offset: inout Int) -> Data? {
        guard let size = data.readUInt32BigEndian(at: &offset),
              data.count - offset >= Int(size) else { return nil }
        defer { offset += Int(size) }
        return data.subdata(in: offset..<(offset + Int(size)))
    }

    private func handleJSONPayload(_ payload: Data, isLast: Bool) {
        if let json = try? JSONSerialization.jsonObject(with: payload),
           let text = extractText(from: json),
           !text.isEmpty {
            latestText = text
            onTranscript?(text, false)
        }
        if isLast {
            complete(with: latestText)
        }
    }

    private func extractText(from value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let result = dictionary["result"],
               let text = extractText(from: result) {
                return text
            }
            if let text = dictionary["text"] as? String {
                return text
            }
            if let payload = dictionary["payload_msg"],
               let text = extractText(from: payload) {
                return text
            }
            if let utterances = dictionary["utterances"],
               let text = extractText(from: utterances) {
                return text
            }
        } else if let array = value as? [Any] {
            let texts = array.compactMap { extractText(from: $0) }
            if !texts.isEmpty {
                return texts.joined()
            }
        }
        return nil
    }

    private func complete(with text: String) {
        guard !closed else { return }
        onTranscript?(text, true)
        close(code: .normalClosure)
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        onError?(message)
        close(code: .goingAway)
    }

    private func close(code: URLSessionWebSocketTask.CloseCode) {
        guard !closed else { return }
        closed = true
        pendingPackets.removeAll()
        task?.cancel(with: code, reason: nil)
        task = nil
    }
}

/// ElevenLabs Scribe v2 Realtime WebSocket 客户端(JSON 文本消息 + base64 PCM)。
final class ElevenLabsRealtimeASRClient: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onPreview: ((String) -> Void)?
    private var finishSettle: DispatchWorkItem?

    private static let chunkBytes = 3_200  // 16kHz * 16bit * 100ms

    private let endpoint: String
    private let apiKey: String
    private let model: String
    private let queue = DispatchQueue(label: "com.wentao.voxboardmac.elevenlabs-realtime")

    private var task: URLSessionWebSocketTask?
    private var audioRemainder = Data()
    private var started = false
    private var finishing = false
    private var closed = false
    // 一次 WebSocket 会话可以产生多个 committed segment;partial 只属于当前未提交 segment。
    private var committedText = ""
    private var lastCommittedEventText = ""
    private var latestText = ""

    init(endpoint: String, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.closed else { return }
            self.started = true

            var comps = URLComponents(string: self.endpoint)!
            comps.queryItems = [
                URLQueryItem(name: "model_id", value: self.model),
                URLQueryItem(name: "audio_format", value: "pcm_16000"),
                URLQueryItem(name: "commit_strategy", value: "vad"),
                URLQueryItem(name: "vad_silence_threshold_secs", value: "1.5"),
                // 不传单一 language_code,让 Scribe 自动识别并支持中英文中途切换。
                URLQueryItem(name: "include_language_detection", value: "true"),
            ]
            guard let url = comps.url else {
                self.fail("ElevenLabs endpoint 无效"); return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue(self.apiKey, forHTTPHeaderField: "xi-api-key")

            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            self.receiveNextMessage()
        }
    }

    func appendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.audioRemainder.append(data)
            while self.audioRemainder.count >= Self.chunkBytes {
                let chunk = self.audioRemainder.prefix(Self.chunkBytes)
                self.audioRemainder.removeFirst(Self.chunkBytes)
                self.sendAudioChunk(Data(chunk), commit: false)
            }
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.finishing = true
            let tail = self.audioRemainder
            self.audioRemainder.removeAll(keepingCapacity: false)
            // 发送剩余音频并 commit,触发 committed_transcript 最终结果。
            self.sendAudioChunk(tail, commit: true)
            // Never promote an unconfirmed partial to committed text on timeout.
            self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.closed else { return }
                self.fail("收尾超时，已保留确认文字，末段未确认")
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.close(code: .goingAway) }
    }

    private func sendAudioChunk(_ audio: Data, commit: Bool) {
        guard let task, !closed else { return }
        let message: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": audio.base64EncodedString(),
            "commit": commit,
            "sample_rate": 16_000,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { [weak self] error in
            guard let error else { return }
            self?.queue.async { self?.fail("发送音频失败：\(error.localizedDescription)") }
        }
    }

    private func receiveNextMessage() {
        guard !closed, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .success(.string(let string)):
                    self.handleMessage(Data(string.utf8))
                case .success(.data(let data)):
                    self.handleMessage(data)
                case .failure(let error):
                    self.fail("连接中断：\(error.localizedDescription)")
                @unknown default:
                    self.fail("收到未知的 WebSocket 消息")
                }
                if !self.closed { self.receiveNextMessage() }
            }
        }
    }

    func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["message_type"] as? String else { return }
        switch type {
        case "session_started":
            break
        case "partial_transcript":
            if let text = json["text"] as? String, !text.isEmpty {
                // 新 partial 代表已进入下一 segment;允许下一次出现相同文本时正常提交。
                lastCommittedEventText = ""
                latestText = joinTranscriptSegments(committedText, text)
                onPreview?(latestText)
                finishSettle?.cancel()
            }
        case "committed_transcript":
            let segment = (json["text"] as? String) ?? ""
            // Timestamp events are ignored; identical consecutive spoken segments are valid.
            if !segment.isEmpty {
                committedText = joinTranscriptSegments(committedText, segment)
                latestText = committedText
                lastCommittedEventText = segment
            }
            if finishing {
                onTranscript?(committedText, false)
                finishSettle?.cancel()
                let settle = DispatchWorkItem { [weak self] in
                    guard let self, !self.closed else { return }
                    self.complete(with: self.committedText)
                }
                finishSettle = settle
                queue.asyncAfter(deadline: .now() + 2, execute: settle)
            } else if !latestText.isEmpty {
                // 自动/中途 commit 只是固定当前段,不代表整次听写结束。
                onTranscript?(latestText, false)
            }
        default:
            // auth_error / quota_exceeded / rate_limited / input_error / transcriber_error …
            if type.hasSuffix("_error") || json["error"] != nil {
                let detail = (json["error"] as? String) ?? type
                fail("ElevenLabs：\(detail)")
            }
        }
    }

    private func complete(with text: String) {
        guard !closed else { return }
        onTranscript?(text, true)
        close(code: .normalClosure)
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        onError?(message)
        close(code: .goingAway)
    }

    private func close(code: URLSessionWebSocketTask.CloseCode) {
        guard !closed else { return }
        closed = true
        finishSettle?.cancel()
        task?.cancel(with: code, reason: nil)
        task = nil
    }
}

enum Gzip {
    private static let bufferSize = 32_768

    static func compress(_ data: Data) -> Data? {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var result = Data()
        var status = Z_OK
        data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(
                mutating: input.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(input.count)

            repeat {
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                let produced = buffer.withUnsafeMutableBytes { output -> Int in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    status = deflate(&stream, Z_FINISH)
                    return output.count - Int(stream.avail_out)
                }
                result.append(contentsOf: buffer.prefix(produced))
            } while status == Z_OK
        }
        return status == Z_STREAM_END ? result : nil
    }

    static func decompress(_ data: Data) -> Data? {
        var stream = z_stream()
        let initialized = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var result = Data()
        var status = Z_OK
        data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(
                mutating: input.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(input.count)

            repeat {
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                let produced = buffer.withUnsafeMutableBytes { output -> Int in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return output.count - Int(stream.avail_out)
                }
                result.append(contentsOf: buffer.prefix(produced))
            } while status == Z_OK
        }
        return status == Z_STREAM_END ? result : nil
    }
}

extension Data {
    mutating func appendInt32BigEndian(_ value: Int32) {
        append(UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> 24))
        append(UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> 16))
        append(UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> 8))
        append(UInt8(truncatingIfNeeded: UInt32(bitPattern: value)))
    }

    mutating func appendUInt32BigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    func readUInt32BigEndian(at offset: inout Int) -> UInt32? {
        guard count - offset >= 4 else { return nil }
        let value = UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
        offset += 4
        return value
    }

    func readInt32BigEndian(at offset: inout Int) -> Int32? {
        guard let value = readUInt32BigEndian(at: &offset) else { return nil }
        return Int32(bitPattern: value)
    }
}

/// OpenAI 原生流式听写(gpt-realtime-whisper)。录音器统一产出 16k PCM,
/// 这里只为 OpenAI 转成其要求的 24k 单声道 PCM;每约 2 秒提交一个 item,
/// 让气泡持续拿到增量结果。
final class OpenAIRealtimeWhisperClient: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private static let minimumCommitBytes = 4_800 // 24kHz / 10 * 16bit = 100ms
    private static let streamingCommitBytes = 96_000 // 约 2 秒

    private let apiKey: String
    private let queue = DispatchQueue(label: "com.wentao.voxboardmac.openai-realtime")
    private var task: URLSessionWebSocketTask?
    private var resampler = PCM16Resampler16To24()
    private var pendingAudio = Data()
    private var uncommittedBytes = 0
    private var configured = false
    private var started = false
    private var finishing = false
    private var closed = false
    private var commitsSent = 0
    private var completedItemIDs = Set<String>()
    private var itemOrder: [String] = []
    private var itemTexts: [String: String] = [:]

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.closed else { return }
            self.started = true
            guard !self.apiKey.isEmpty else {
                self.fail("OpenAI：请先在设置中填写 API Key")
                return
            }

            var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
            components.queryItems = [
                URLQueryItem(name: "intent", value: "transcription")
            ]
            guard let url = components.url else {
                self.fail("OpenAI Realtime endpoint 无效")
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")

            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            self.receiveNextMessage()

            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !self.closed, !self.configured else { return }
                self.fail("OpenAI Realtime 连接超时")
            }
        }
    }

    func appendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            let converted = self.resampler.convert(data)
            guard !converted.isEmpty else { return }
            if self.configured {
                self.sendAudio(converted)
            } else {
                self.pendingAudio.append(converted)
            }
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.finishing = true
            if self.configured {
                self.commitIfPossible(force: true)
                self.completeIfReady()
            }
            self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, !self.closed else { return }
                self.complete(with: self.combinedText())
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.close(code: .goingAway) }
    }

    private func sendSessionUpdate() {
        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": [
                            "model": "gpt-realtime-whisper",
                            "delay": "low",
                        ],
                        "noise_reduction": ["type": "near_field"],
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        sendJSON(event)
    }

    private func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        sendJSON([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
        uncommittedBytes += data.count
        commitIfPossible(force: false)
    }

    private func commitIfPossible(force: Bool) {
        let threshold = force ? Self.minimumCommitBytes : Self.streamingCommitBytes
        guard uncommittedBytes >= threshold else { return }
        sendJSON(["type": "input_audio_buffer.commit"])
        commitsSent += 1
        uncommittedBytes = 0
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task, !closed,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { [weak self] error in
            guard let error else { return }
            self?.queue.async {
                self?.fail("OpenAI 发送失败：\(error.localizedDescription)")
            }
        }
    }

    private func receiveNextMessage() {
        guard !closed, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .success(.string(let string)):
                    self.handleMessage(Data(string.utf8))
                case .success(.data(let data)):
                    self.handleMessage(data)
                case .failure(let error):
                    self.fail("OpenAI 连接中断：\(error.localizedDescription)")
                @unknown default:
                    self.fail("OpenAI 返回了未知消息")
                }
                if !self.closed { self.receiveNextMessage() }
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "session.created", "transcription_session.created":
            // 等服务端确认 WebSocket 已建立后再配置,避免第一条消息抢在握手前发送。
            sendSessionUpdate()
        case "session.updated", "transcription_session.updated":
            configured = true
            if !pendingAudio.isEmpty {
                let audio = pendingAudio
                pendingAudio.removeAll(keepingCapacity: false)
                sendAudio(audio)
            }
            if finishing {
                commitIfPossible(force: true)
                completeIfReady()
            }
        case "input_audio_buffer.committed":
            if let itemID = json["item_id"] as? String {
                ensureItemOrder(itemID)
            }
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = json["item_id"] as? String,
                  let delta = json["delta"] as? String, !delta.isEmpty else { return }
            ensureItemOrder(itemID)
            itemTexts[itemID, default: ""] += delta
            onTranscript?(combinedText(), false)
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = json["item_id"] as? String else { return }
            ensureItemOrder(itemID)
            if let transcript = json["transcript"] as? String {
                itemTexts[itemID] = transcript
            }
            completedItemIDs.insert(itemID)
            if finishing {
                completeIfReady()
            } else {
                onTranscript?(combinedText(), false)
            }
        case "conversation.item.input_audio_transcription.failed":
            fail("OpenAI 转写失败：\(errorMessage(in: json))")
        case "error":
            fail("OpenAI：\(errorMessage(in: json))")
        default:
            break
        }
    }

    private func ensureItemOrder(_ itemID: String) {
        if !itemOrder.contains(itemID) { itemOrder.append(itemID) }
    }

    private func combinedText() -> String {
        itemOrder.reduce(into: "") { result, itemID in
            result = joinTranscriptSegments(result, itemTexts[itemID] ?? "")
        }
    }

    private func completeIfReady() {
        if commitsSent == 0 {
            if uncommittedBytes < Self.minimumCommitBytes {
                complete(with: combinedText())
            }
            return
        }
        guard completedItemIDs.count >= commitsSent else { return }
        complete(with: combinedText())
    }

    private func errorMessage(in json: [String: Any]) -> String {
        if let error = json["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String) ?? "未知错误"
        }
        return (json["message"] as? String) ?? "未知错误"
    }

    private func complete(with text: String) {
        guard !closed else { return }
        onTranscript?(text, true)
        close(code: .normalClosure)
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        onError?(message)
        close(code: .goingAway)
    }

    private func close(code: URLSessionWebSocketTask.CloseCode) {
        guard !closed else { return }
        closed = true
        pendingAudio.removeAll()
        task?.cancel(with: code, reason: nil)
        task = nil
    }
}

/// GPT-4o Transcribe 两档使用标准 Audio Transcriptions API。它们不是原生实时模型,
/// 因而先收集一段 16k PCM,停止录音时封装成 WAV 后一次上传(无 partial)。
final class OpenAITranscriptionClient: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let model: String
    private let queue = DispatchQueue(label: "com.wentao.voxboardmac.openai-transcription")
    private var audio = Data()
    private var requestTask: URLSessionDataTask?
    private var started = false
    private var finishing = false
    private var closed = false

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.closed else { return }
            self.started = true
            if self.apiKey.isEmpty {
                self.fail("OpenAI：请先在设置中填写 API Key")
            }
        }
    }

    func appendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.audio.append(data)
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.finishing = true
            guard !self.audio.isEmpty else {
                self.complete(with: "")
                return
            }
            self.upload()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.requestTask?.cancel()
            self.requestTask = nil
            self.audio.removeAll()
        }
    }

    private func upload() {
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            fail("OpenAI Transcriptions endpoint 无效")
            return
        }
        var form = MultipartFormBody()
        form.addField("model", model)
        form.addField("response_format", "json")
        form.addFile(
            "file",
            filename: "voxboard.wav",
            mimeType: "audio/wav",
            data: makeWAV(fromPCM16: audio, sampleRate: 16_000)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let error {
                    self.fail("OpenAI 请求失败：\(error.localizedDescription)")
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.fail("OpenAI 返回内容无法解析（HTTP \(status)）")
                    return
                }
                if (200..<300).contains(status), let text = json["text"] as? String {
                    self.complete(with: text)
                } else {
                    let errorObject = json["error"] as? [String: Any]
                    let message = (errorObject?["message"] as? String) ?? "HTTP \(status)"
                    self.fail("OpenAI：\(message)")
                }
            }
        }
        requestTask = task
        task.resume()
    }

    private func makeWAV(fromPCM16 pcm: Data, sampleRate: UInt32) -> Data {
        var wav = Data()
        wav.append(Data("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav) // PCM
        appendLittleEndian(UInt16(1), to: &wav) // mono
        appendLittleEndian(sampleRate, to: &wav)
        appendLittleEndian(sampleRate * 2, to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func complete(with text: String) {
        guard !closed else { return }
        onTranscript?(text, true)
        closed = true
        requestTask = nil
        audio.removeAll()
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        onError?(message)
        closed = true
        requestTask?.cancel()
        requestTask = nil
        audio.removeAll()
    }
}

/// ElevenLabs Scribe v2 离线识别:录音期间只在本机累积 16k PCM,停止后整段上传。
/// 比 Realtime 多等几秒,但模型能看到完整上下文;裸 PCM 直接上传,不必封装 WAV。
final class ElevenLabsTranscriptionClient: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    struct ResponseError: Error, Equatable {
        let message: String
    }

    /// 服务端要求至少 100ms 音频。
    private static let minimumBytes = 3_200

    private let apiKey: String
    private let model: String
    private let queue = DispatchQueue(label: "com.wentao.voxboardmac.elevenlabs-transcription")
    private var audio = Data()
    /// Requests in flight. A stalled connection (seen through proxies: TLS up, then
    /// nothing) used to block for the whole timeout; now a second copy is sent after
    /// `hedgeDelay` and the first answer wins.
    private var inFlight: [Int: URLSessionDataTask] = [:]
    private var uploadAttempts = 0
    private var hedgeTimer: DispatchWorkItem?
    static let maxAttempts = 3
    private var started = false
    private var finishing = false
    private var closed = false

    private let session: URLSession
    private let hedgeDelayOverride: TimeInterval?

    init(apiKey: String, model: String, session: URLSession = .shared, hedgeDelay: TimeInterval? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.hedgeDelayOverride = hedgeDelay
    }

    private var currentHedgeDelay: TimeInterval { hedgeDelayOverride ?? Self.hedgeDelay(audioBytes: audio.count) }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.closed else { return }
            self.started = true
            if self.apiKey.isEmpty {
                self.fail("ElevenLabs：请先在设置中填写 API Key")
            }
        }
    }

    func appendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.audio.append(data)
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, self.started, !self.finishing, !self.closed else { return }
            self.finishing = true
            guard self.audio.count >= Self.minimumBytes else {
                self.complete(with: "")
                return
            }
            self.upload()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.stopRequests()
            self.audio.removeAll()
        }
    }

    /// How long to wait for an answer before sending another copy: upload time grows with
    /// the recording (32 KB/s of PCM), transcription is fast. 3 s for a short phrase.
    static func hedgeDelay(audioBytes: Int) -> TimeInterval {
        let seconds = Double(audioBytes) / 32_000
        return min(30, 3 + seconds / 8)
    }

    static func makeRequest(pcm: Data, apiKey: String, model: String) -> URLRequest {
        var form = MultipartFormBody()
        form.addField("model_id", model)
        form.addField("file_format", "pcm_s16le_16")
        // 听写只要文字:不标注 (笑声) 之类的声音事件,不返回逐词时间戳。
        form.addField("tag_audio_events", "false")
        form.addField("timestamps_granularity", "none")
        form.addFile("file", filename: "voxboard.pcm", mimeType: "application/octet-stream", data: pcm)

        var request = URLRequest(url: elevenLabsTranscriptionEndpoint)
        request.httpMethod = "POST"
        // Idle timeout between packets; a stall is also covered by hedging.
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        return request
    }

    /// 成功返回转写文本;失败返回可直接展示的错误说明。
    static func parseResponse(_ data: Data?, status: Int) -> Result<String, ResponseError> {
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if (200..<300).contains(status), let text = json?["text"] as? String {
            return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // 401/400 等是 {"detail": {"message": …}},422 校验错误是 {"detail": [{"msg": …}]}。
        let detail = json?["detail"]
        let message = (detail as? [String: Any])?["message"] as? String
            ?? ((detail as? [[String: Any]])?.first?["msg"] as? String)
            ?? (detail as? String)
            ?? "HTTP \(status)"
        return .failure(ResponseError(message: "ElevenLabs：\(message)"))
    }

    private func upload() {
        guard !closed, uploadAttempts < Self.maxAttempts else { return }
        uploadAttempts += 1
        let attempt = uploadAttempts
        let request = Self.makeRequest(pcm: audio, apiKey: apiKey, model: model)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.inFlight[attempt] = nil
                if let error {
                    if (error as? URLError)?.code == .cancelled { return }
                    NSLog("ElevenLabs upload attempt %d failed: %@", attempt, error.localizedDescription)
                    // The recording only lives in memory: retry transport failures. Another
                    // copy may still be on its way; only give up when none is left.
                    if self.uploadAttempts < Self.maxAttempts {
                        self.upload()
                    } else if self.inFlight.isEmpty {
                        self.fail("ElevenLabs 请求失败：\(error.localizedDescription)")
                    }
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch Self.parseResponse(data, status: status) {
                case let .success(text): self.complete(with: text)
                case let .failure(error): self.fail(error.message) // HTTP errors are not retried
                }
            }
        }
        inFlight[attempt] = task
        task.resume()
        scheduleHedge()
    }

    private func scheduleHedge() {
        hedgeTimer?.cancel()
        guard uploadAttempts < Self.maxAttempts else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.closed, !self.inFlight.isEmpty else { return }
            NSLog("ElevenLabs: no answer after %.1fs, sending another copy", self.currentHedgeDelay)
            self.upload()
        }
        hedgeTimer = work
        queue.asyncAfter(deadline: .now() + currentHedgeDelay, execute: work)
    }

    private func stopRequests() {
        hedgeTimer?.cancel()
        hedgeTimer = nil
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private func complete(with text: String) {
        guard !closed else { return }
        onTranscript?(text, true)
        closed = true
        stopRequests()
        audio.removeAll()
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        onError?(message)
        closed = true
        stopRequests()
        audio.removeAll()
    }
}

/// 整段上传类引擎共用的 multipart/form-data 请求体。
struct MultipartFormBody {
    let boundary = "VoxBoardMac-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}

/// 线性插值的流式 16k -> 24k PCM16 重采样器。保留跨音频块的相位和末尾采样点,
/// 避免每个 tap buffer 边界出现跳点。
struct PCM16Resampler16To24 {
    private var samples: [Double] = []
    private var sourcePosition = 0.0

    mutating func convert(_ data: Data) -> Data {
        guard data.count >= 2 else { return Data() }
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            while index + 1 < bytes.count {
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                samples.append(Double(Int16(bitPattern: bits)))
                index += 2
            }
        }

        var output = Data()
        output.reserveCapacity(Int(Double(data.count) * 1.5) + 4)
        let sourceStep = 2.0 / 3.0
        while sourcePosition < Double(samples.count - 1) {
            let lowerIndex = Int(sourcePosition)
            let fraction = sourcePosition - Double(lowerIndex)
            let interpolated = samples[lowerIndex]
                + (samples[lowerIndex + 1] - samples[lowerIndex]) * fraction
            let sample = Int16(clamping: Int(interpolated.rounded()))
            let bits = UInt16(bitPattern: sample)
            output.append(UInt8(bits & 0xff))
            output.append(UInt8((bits >> 8) & 0xff))
            sourcePosition += sourceStep
        }

        let consumed = Int(sourcePosition)
        if consumed > 0 {
            samples.removeFirst(min(consumed, samples.count))
            sourcePosition -= Double(consumed)
        }
        return output
    }
}
