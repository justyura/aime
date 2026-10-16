import AIMEAI
import Foundation

/// VoxBoardMac's preferences (`com.wentao.voxboard.mac`): the fallback for anything not
/// set in AIME, so an existing VoxBoard setup works unchanged. Nothing secret is bundled.
enum VoiceDefaults {
    static let domain: String = {
        let custom = VoiceSettings.aimeDefaults.string(forKey: "voice.preferencesDomain") ?? ""
        return custom.isEmpty ? "com.wentao.voxboard.mac" : custom
    }()

    nonisolated(unsafe) static let store: UserDefaults = UserDefaults(suiteName: domain) ?? .standard
}

/// ASR engines ported from VoxBoardMac. Raw values match VoxBoard's `asrEngine` key.
public enum VoiceEngineChoice: String, CaseIterable, Sendable, Identifiable {
    case volc
    case vox
    case elevenlabs
    case elevenlabsBatch
    case tencent
    case tencentSentence
    case openai4o
    case openai4oMini
    case openaiWhisper

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vox: "Vox（自建）"
        case .volc: "豆包（火山）"
        case .elevenlabs: "ElevenLabs 实时"
        case .elevenlabsBatch: "ElevenLabs（说完后转写）"
        case .tencent: "腾讯云实时"
        case .tencentSentence: "腾讯云一句话"
        case .openai4o: "OpenAI GPT-4o Transcribe"
        case .openai4oMini: "OpenAI GPT-4o mini Transcribe"
        case .openaiWhisper: "OpenAI Realtime Whisper"
        }
    }

    /// Engines that only transcribe after the recording stops (no partial results).
    public var isBatch: Bool {
        switch self {
        case .vox, .elevenlabsBatch, .openai4o, .openai4oMini, .tencentSentence: true
        default: false
        }
    }

    /// The settings this engine needs.
    public var fields: [VoiceSettings.Field] {
        switch self {
        case .elevenlabs, .elevenlabsBatch: [.elevenLabsKey]
        case .openai4o, .openai4oMini, .openaiWhisper: [.openAIKey]
        case .tencent: [.tencentAppID, .tencentSecretID, .tencentSecretKey]
        case .tencentSentence: [.tencentSecretID, .tencentSecretKey]
        case .volc: [.volcAppKey, .volcAccessKey]
        case .vox: []
        }
    }

    /// How long to wait for a final transcript after the recording stops.
    var finishTimeout: TimeInterval {
        switch self {
        case .vox, .tencentSentence: 900
        case .elevenlabsBatch: 300
        case .volc: 8
        default: 20
        }
    }
}

/// Voice input settings, shared by the input method (reads) and AIME Settings (writes).
///
/// Lookup order for every value: AIME's own setting → VoxBoardMac's preferences. Secrets
/// live in AIME's owner-only credentials file (as the AI assistant's key does), other
/// values in the input method's defaults domain.
public enum VoiceSettings {
    public static let imeDomain = "app.zool.inputmethod.aime"

    nonisolated(unsafe) static let aimeDefaults: UserDefaults =
        Bundle.main.bundleIdentifier == imeDomain ? .standard : (UserDefaults(suiteName: imeDomain) ?? .standard)

    public enum Field: String, CaseIterable, Sendable, Identifiable {
        case elevenLabsKey, openAIKey, tencentAppID, tencentSecretID, tencentSecretKey, volcAppKey, volcAccessKey

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .elevenLabsKey: "ElevenLabs API Key"
            case .openAIKey: "OpenAI API Key"
            case .tencentAppID: "腾讯云 AppID"
            case .tencentSecretID: "腾讯云 SecretId"
            case .tencentSecretKey: "腾讯云 SecretKey"
            case .volcAppKey: "火山 App Key"
            case .volcAccessKey: "火山 Access Key"
            }
        }

        public var isSecret: Bool {
            switch self {
            case .tencentAppID, .volcAppKey: false
            default: true
            }
        }

        /// The same setting in VoxBoardMac's preferences.
        var voxBoardKey: String {
            switch self {
            case .elevenLabsKey: "elevenLabsKeyUser"
            case .openAIKey: "openAIKeyUser"
            case .tencentAppID: "tencentAppID"
            case .tencentSecretID: "tencentSecretID"
            case .tencentSecretKey: "tencentSecretKey"
            case .volcAppKey: "volcAppKey"
            case .volcAccessKey: "volcAccessKey"
            }
        }

        var aimeKey: String { "voice.\(rawValue)" }
        var credential: CredentialStore { CredentialStore(account: aimeKey) }
    }

    public enum Source: Sendable { case aime, voxBoard, missing }

    // MARK: - Switch, engine, microphone

    public static var isEnabled: Bool {
        get { aimeDefaults.bool(forKey: "voice.enabled") }
        set { aimeDefaults.set(newValue, forKey: "voice.enabled") }
    }

    public static var engine: VoiceEngineChoice {
        get { VoiceEngineChoice(rawValue: string("voice.engine", fallback: "asrEngine")) ?? .elevenlabsBatch }
        set { aimeDefaults.set(newValue.rawValue, forKey: "voice.engine") }
    }

    static var microphoneUID: String? {
        let uid = string("voice.micDeviceUID", fallback: "micDeviceUID")
        return uid.isEmpty ? nil : uid
    }

    // MARK: - Fields

    /// The effective value: AIME's own, else VoxBoard's.
    public static func value(_ field: Field) -> String {
        let own = ownValue(field)
        return own.isEmpty ? trimmed(VoiceDefaults.store.string(forKey: field.voxBoardKey)) : own
    }

    /// AIME's own value only (empty when it falls back to VoxBoard).
    public static func ownValue(_ field: Field) -> String {
        if field.isSecret, let saved = field.credential.read() { return trimmed(saved) }
        return trimmed(aimeDefaults.string(forKey: field.aimeKey))
    }

    public static func source(_ field: Field) -> Source {
        if !ownValue(field).isEmpty { return .aime }
        return value(field).isEmpty ? .missing : .voxBoard
    }

    /// Saves AIME's own value; empty removes it (falling back to VoxBoard again).
    @discardableResult
    public static func set(_ field: Field, _ newValue: String) -> Bool {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if field.isSecret {
            aimeDefaults.removeObject(forKey: field.aimeKey)
            return field.credential.write(value.isEmpty ? nil : value)
        }
        if value.isEmpty { aimeDefaults.removeObject(forKey: field.aimeKey) } else { aimeDefaults.set(value, forKey: field.aimeKey) }
        return true
    }

    /// AIME's own setting first, then the shared VoxBoard key.
    static func string(_ aimeKey: String, fallback sharedKey: String) -> String {
        let own = trimmed(aimeDefaults.string(forKey: aimeKey))
        return own.isEmpty ? trimmed(VoiceDefaults.store.string(forKey: sharedKey)) : own
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Engines

    static func makeEngine(_ choice: VoiceEngineChoice) -> any RealtimeASREngine {
        switch choice {
        case .vox:
            return VoxDictationEngine()
        case .tencent:
            return TencentRealtimeASRClient(
                appID: value(.tencentAppID), secretID: value(.tencentSecretID), secretKey: value(.tencentSecretKey))
        case .tencentSentence:
            return TencentSegmentedASRClient(
                secretID: value(.tencentSecretID), secretKey: value(.tencentSecretKey),
                model: string("voice.tencentSentenceLanguage", fallback: "tencentSentenceLanguage") == "en"
                    ? "16k_en" : "16k_zh-PY"
            )
        case .elevenlabs:
            return ElevenLabsRealtimeASRClient(
                endpoint: elevenLabsRealtimeEndpoint, apiKey: value(.elevenLabsKey), model: elevenLabsModel)
        case .elevenlabsBatch:
            return ElevenLabsTranscriptionClient(apiKey: value(.elevenLabsKey), model: elevenLabsBatchModel)
        case .openai4o:
            return OpenAITranscriptionClient(apiKey: value(.openAIKey), model: "gpt-4o-transcribe")
        case .openai4oMini:
            return OpenAITranscriptionClient(apiKey: value(.openAIKey), model: "gpt-4o-mini-transcribe")
        case .openaiWhisper:
            return OpenAIRealtimeWhisperClient(apiKey: value(.openAIKey))
        case .volc:
            return DoubaoRealtimeASRClient(
                endpoint: volcRealtimeEndpoint, appKey: value(.volcAppKey), accessKey: value(.volcAccessKey),
                resourceID: volcRealtimeResourceId)
        }
    }

    /// Sends one second of silence through `choice` to check the key and the network.
    /// Batch engines only: realtime ones need speech to answer. Completion on main.
    public static func testConnection(_ choice: VoiceEngineChoice, completion: @escaping @Sendable (Result<Void, VoiceTestError>) -> Void) {
        guard choice.isBatch, choice != .vox else {
            return DispatchQueue.main.async { completion(.failure(.unsupported)) }
        }
        let engine = makeEngine(choice)
        let box = TestBox(engine: engine)
        engine.onTranscript = { _, final in
            guard final, box.finish() else { return }
            DispatchQueue.main.async { completion(.success(())) }
        }
        engine.onError = { message in
            guard box.finish() else { return }
            DispatchQueue.main.async { completion(.failure(.failed(message))) }
        }
        engine.start()
        for _ in 0..<10 { engine.appendAudio(Data(count: 3_200)) }
        engine.finish()
    }
}

public enum VoiceTestError: Error, Sendable {
    case unsupported
    case failed(String)

    public var message: String {
        switch self {
        case .unsupported: "实时引擎需要实际说话才能测试：在任意输入框轻按右 Shift 试一句"
        case let .failed(message): message
        }
    }
}

/// Keeps the engine alive until it answers, and lets only the first answer through.
private final class TestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: (any RealtimeASREngine)?
    init(engine: any RealtimeASREngine) { self.engine = engine }
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard engine != nil else { return false }
        engine = nil
        return true
    }
}
