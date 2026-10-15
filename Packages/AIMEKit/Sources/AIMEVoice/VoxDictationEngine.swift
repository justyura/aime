import Foundation

/// Adapts Vox's asynchronous file API to the existing microphone engine contract.
final class VoxDictationEngine: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.wentao.voxboard.vox-dictation")
    private var audio = Data()
    private var started = false
    private var closed = false
    private var finishing = false
    private var work: Task<Void, Never>?
    private var token = ""

    func start() {
        queue.async {
            guard !self.started, !self.closed else { return }
            self.started = true
            self.token = VoiceDefaults.store.string(forKey: VoxAPIClient.tokenDefaultsKey) ?? ""
            if self.token.isEmpty { self.complete(.failure(VoxAPIClient.ClientError.notAuthenticated)) }
        }
    }

    func appendAudio(_ data: Data) {
        queue.async {
            guard self.started, !self.closed, !self.finishing else { return }
            guard self.audio.count + data.count <= 32_000 * 600 else {
                self.complete(.failure(NSError(domain: "Vox", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "单次 Vox 听写最多 10 分钟"])))
                return
            }
            self.audio.append(data)
        }
    }

    func finish() {
        queue.async {
            guard self.started, !self.closed, !self.finishing else { return }
            self.finishing = true
            guard !self.audio.isEmpty else { self.complete(.success("")); return }
            NSLog("Vox dictation: uploading %.3f seconds of PCM", Double(self.audio.count) / 32_000)
            let wav = Self.wav(self.audio)
            self.audio.removeAll()
            let token = self.token
            let client = VoxAPIClient(token: token)
            self.work = Task {
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vox-dictation-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: file) }
                do {
                    try Task.checkCancellation()
                    try wav.write(to: file, options: .atomic)
                    let ticket = try await client.uploadTicket(filename: "dictation.wav")
                    try await client.putFile(at: file, to: ticket.uploadURL)
                    try await client.completeUpload(fileID: ticket.fileID)
                    try Task.checkCancellation()
                    let id = try await client.createTranscriptionTask(fileID: ticket.fileID)
                    let result = try await client.waitForCompletion(taskID: id)
                    let raw = try await client.downloadResult(fileID: result.outputFileID)
                    let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
                    let text = (object?["text"] as? String ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.queue.async { self.complete(.success(text)) }
                } catch {
                    if case VoxAPIClient.ClientError.server(status: 401, message: _) = error,
                       VoiceDefaults.store.string(forKey: VoxAPIClient.tokenDefaultsKey) == token {
                        VoiceDefaults.store.removeObject(forKey: VoxAPIClient.tokenDefaultsKey)
                    }
                    self.queue.async { self.complete(.failure(error)) }
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.closed = true
            self.work?.cancel()
            self.work = nil
            self.audio.removeAll()
        }
    }

    private func complete(_ result: Result<String, Error>) {
        guard !closed else { return }
        closed = true
        work = nil
        audio.removeAll()
        switch result {
        case .success(let text): onTranscript?(text, true)
        case .failure(let error): onError?("Vox：\(error.localizedDescription)；请在识别引擎页检查登录状态")
        }
    }

    static func wav(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
