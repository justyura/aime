import AVFoundation
import Foundation

/// One dictation at a time: microphone → streaming ASR → partial / final text.
///
/// UI-free port of VoxBoardMac's DictationController: the input method decides how text
/// reaches the client (marked text while speaking, a commit at the end). All callbacks
/// arrive on the main queue. A tag drops late callbacks from an abandoned connection.
public final class VoiceDictation {
    public enum State: Equatable, Sendable { case idle, recording, finishing }

    public private(set) var state: State = .idle
    public private(set) var activeEngine: VoiceEngineChoice = .volc
    /// Cumulative transcript of the current utterance so far.
    public var onPartial: ((String) -> Void)?
    /// The utterance is done; empty when nothing was recognized or it was cancelled.
    public var onFinal: ((String) -> Void)?
    /// A short message for the user (errors, permission hints).
    public var onNotice: ((String) -> Void)?
    public var onStateChange: ((State) -> Void)?

    private let capture = AudioCapture()
    private let audioRouter = PrerollAudioRouter(maxBytes: 96_000)
    private var engine: (any RealtimeASREngine)?
    private var currentTag = ""
    private var latestText = ""
    private var prepared = false

    public init() {}

    public var isActive: Bool { state != .idle }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    /// Right Shift down: record into a local pre-roll buffer so the first syllable is
    /// kept. Nothing leaves the machine until `start()` confirms the tap.
    public func prepare() {
        guard state == .idle, !prepared,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        prepared = true
        audioRouter.startBuffering()
        do {
            try startCapture()
        } catch {
            cancelPrepared()
        }
    }

    public func cancelPrepared() {
        guard prepared else { return }
        prepared = false
        capture.stop()
        audioRouter.reset()
    }

    public func start() {
        guard state == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            reallyStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.reallyStart() } else { self?.onNotice?("未获得麦克风权限") }
                }
            }
        default:
            onNotice?("请在 系统设置 › 隐私与安全性 › 麦克风 中允许 AIME")
        }
    }

    private func reallyStart() {
        guard state == .idle else { return }
        let hasPreroll = prepared && capture.isRunning
        prepared = false
        activeEngine = VoiceSettings.engine
        let choice = activeEngine
        let tag = UUID().uuidString
        currentTag = tag
        latestText = ""

        let client = VoiceSettings.makeEngine(choice)
        if let eleven = client as? ElevenLabsRealtimeASRClient {
            eleven.onPreview = { [weak self] text in
                DispatchQueue.main.async {
                    guard let self, self.currentTag == tag, !text.isEmpty else { return }
                    self.onPartial?(text)
                }
            }
        }
        client.onTranscript = { [weak self] text, isFinal in
            DispatchQueue.main.async {
                guard let self, self.currentTag == tag else { return }
                let clean = choice == .elevenlabs ? text : normalizeTranscriptPunctuation(text)
                if !clean.isEmpty {
                    self.latestText = clean
                    if !isFinal { self.onPartial?(clean) }
                }
                if isFinal { self.finish(with: self.latestText) }
            }
        }
        client.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.currentTag == tag else { return }
                NSLog("AIME voice: ASR error: %@", message)
                if self.latestText.isEmpty {
                    self.onNotice?("识别失败：\(message)")
                    self.finish(with: "")
                } else {
                    // Keep what was already recognized rather than losing the utterance.
                    self.onNotice?("已保留已有文字；\(message)")
                    self.finish(with: self.latestText)
                }
            }
        }
        engine = client
        client.start()
        setState(.recording)

        let sink: (Data) -> Void = { [weak client] data in client?.appendAudio(data) }
        do {
            if hasPreroll {
                audioRouter.promote(to: sink)
            } else {
                audioRouter.goLive(sink)
                try startCapture()
            }
        } catch {
            onNotice?("麦克风启动失败：\(error.localizedDescription)")
            cancel()
        }
    }

    /// Stop listening and wait for the final transcript.
    public func stop() {
        guard state == .recording else { return }
        setState(.finishing)
        capture.stop()
        engine?.finish()
        // Engines have their own fallbacks; this guards a connection that died silently.
        let tag = currentTag
        DispatchQueue.main.asyncAfter(deadline: .now() + activeEngine.finishTimeout) { [weak self] in
            guard let self, self.state == .finishing, self.currentTag == tag else { return }
            self.onNotice?("转写等待超时")
            self.finish(with: self.latestText)
        }
    }

    /// Abandon the utterance: nothing is delivered.
    public func cancel() {
        guard state != .idle || prepared else { return }
        cancelPrepared()
        currentTag = ""
        engine?.cancel()
        engine = nil
        capture.stop()
        audioRouter.reset()
        latestText = ""
        setState(.idle)
    }

    private func finish(with text: String) {
        currentTag = "" // later callbacks are dropped
        engine?.cancel()
        engine = nil
        capture.stop()
        audioRouter.reset()
        setState(.idle)
        onFinal?(text)
    }

    private func startCapture() throws {
        try capture.start(
            deviceUID: VoiceSettings.microphoneUID,
            onChunk: { [weak self] data in self?.audioRouter.append(data) },
            onLevel: { _ in },
            onNotice: { [weak self] message in
                DispatchQueue.main.async { self?.onNotice?(message) }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.onNotice?(message)
                    if self.latestText.isEmpty { self.cancel() } else { self.finish(with: self.latestText) }
                }
            }
        )
    }
}

/// Serializes the audio callback with promotion so pre-roll always precedes live audio.
final class PrerollAudioRouter {
    private enum Mode {
        case idle
        case buffering
        case live((Data) -> Void)
    }

    private let lock = NSLock()
    private let maxBytes: Int
    private var mode: Mode = .idle
    private var buffer = Data()

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func startBuffering() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        mode = .buffering
        lock.unlock()
    }

    func append(_ data: Data) {
        lock.lock()
        switch mode {
        case .idle:
            break
        case .buffering:
            buffer.append(data)
            if buffer.count > maxBytes { buffer.removeFirst(buffer.count - maxBytes) }
        case let .live(sink):
            sink(data)
        }
        lock.unlock()
    }

    func promote(to sink: @escaping (Data) -> Void) {
        lock.lock()
        if !buffer.isEmpty { sink(buffer) }
        buffer.removeAll(keepingCapacity: true)
        mode = .live(sink)
        lock.unlock()
    }

    func goLive(_ sink: @escaping (Data) -> Void) {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        mode = .live(sink)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        mode = .idle
        lock.unlock()
    }
}
