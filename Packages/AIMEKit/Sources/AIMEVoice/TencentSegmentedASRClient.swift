import Foundation

/// Keeps each request below the sentence API's 60-second limit.
final class TencentSegmentedASRClient: RealtimeASREngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "vox.tencent-segments")
    private let secretID: String
    private let secretKey: String
    private let model: String
    private let session: URLSession
    private var audio = Data()
    private var pending: [Data] = []
    private var text = ""
    private var task: URLSessionDataTask?
    private var closed = false
    private var finishing = false
    private var started = false
    static let segmentBytes = 50 * 32_000

    init(secretID: String, secretKey: String, model: String, session: URLSession = .shared) {
        self.secretID = secretID
        self.secretKey = secretKey
        self.model = model
        self.session = session
    }
    func start() {
        queue.async {
            guard !self.closed else { return }
            self.started = true
            if self.secretID.isEmpty || self.secretKey.isEmpty { self.fail("请先填写腾讯云密钥") }
        }
    }
    func appendAudio(_ data: Data) {
        queue.async {
            guard self.started, !self.closed, !self.finishing else { return }
            self.audio.append(data)
            while self.audio.count >= Self.segmentBytes {
                self.pending.append(Data(self.audio.prefix(Self.segmentBytes)))
                self.audio.removeFirst(Self.segmentBytes)
            }
            self.pump()
        }
    }
    func finish() {
        queue.async {
            guard !self.closed, !self.finishing else { return }
            self.finishing = true
            if !self.audio.isEmpty { self.pending.append(self.audio); self.audio.removeAll() }
            self.pump()
        }
    }
    private func pump() {
        guard !closed, task == nil else { return }
        guard !pending.isEmpty else {
            if finishing { closed = true; onTranscript?(text, true) }
            return
        }
        do {
            let request = try TencentSentenceASRClient.makeRequest(audio: pending[0],
                secretID: secretID, secretKey: secretKey, engineModel: model)
            task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    guard !self.closed else { return }
                    self.task = nil
                    do {
                        if let error { throw error }
                        let segment = try TencentSentenceASRClient.parseResponse(data ?? Data(),
                            status: (response as? HTTPURLResponse)?.statusCode ?? 0)
                        self.text = joinTranscriptSegments(self.text, segment)
                        self.pending.removeFirst()
                        self.onTranscript?(self.text, false)
                        self.pump()
                    } catch { self.fail(error.localizedDescription) }
                }
            }
            task?.resume()
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) {
        closed = true
        task?.cancel()
        task = nil
        pending.removeAll()
        audio.removeAll()
        onError?(message)
    }
    func cancel() { queue.async { self.closed = true; self.task?.cancel(); self.task = nil; self.pending.removeAll(); self.audio.removeAll() } }
}
