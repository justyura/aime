import Foundation

/// Where voice input reads its engine choice, microphone and credentials.
///
/// Phase 1 shares VoxBoardMac's preferences (`com.wentao.voxboard.mac`) so an existing
/// VoxBoard setup works unchanged; nothing secret is bundled with AIME. Override the
/// domain with `defaults write app.zool.inputmethod.aime voice.preferencesDomain <id>`.
enum VoiceDefaults {
    static let domain: String = {
        let custom = UserDefaults.standard.string(forKey: "voice.preferencesDomain") ?? ""
        return custom.isEmpty ? "com.wentao.voxboard.mac" : custom
    }()

    nonisolated(unsafe) static let store: UserDefaults = UserDefaults(suiteName: domain) ?? .standard
}

/// ASR engines ported from VoxBoardMac. Raw values match VoxBoard's `asrEngine` key.
public enum VoiceEngineChoice: String, CaseIterable, Sendable {
    case volc
    case vox
    case elevenlabs
    case elevenlabsBatch
    case tencent
    case tencentSentence
    case openai4o
    case openai4oMini
    case openaiWhisper

    public var displayName: String {
        switch self {
        case .vox: "Vox"
        case .volc: "豆包"
        case .elevenlabs: "ElevenLabs 实时"
        case .elevenlabsBatch: "ElevenLabs"
        case .tencent: "腾讯云实时"
        case .tencentSentence: "腾讯云一句话"
        case .openai4o: "GPT-4o Transcribe"
        case .openai4oMini: "GPT-4o mini Transcribe"
        case .openaiWhisper: "OpenAI Whisper"
        }
    }

    /// Engines that only transcribe after the recording stops (no partial results).
    public var isBatch: Bool {
        switch self {
        case .vox, .elevenlabsBatch, .openai4o, .openai4oMini, .tencentSentence: true
        default: false
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

public enum VoiceSettings {
    /// AIME's own switch (`defaults write app.zool.inputmethod.aime voice.enabled -bool true`).
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "voice.enabled")
    }

    public static var engine: VoiceEngineChoice {
        let raw = string("voice.engine", fallback: "asrEngine")
        return VoiceEngineChoice(rawValue: raw) ?? .volc
    }

    static var microphoneUID: String? {
        let uid = string("voice.micDeviceUID", fallback: "micDeviceUID")
        return uid.isEmpty ? nil : uid
    }

    /// AIME's own key wins; otherwise the shared VoxBoard key.
    static func string(_ aimeKey: String, fallback sharedKey: String) -> String {
        let own = UserDefaults.standard.string(forKey: aimeKey) ?? ""
        if !own.isEmpty { return own }
        return (VoiceDefaults.store.string(forKey: sharedKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeEngine(_ choice: VoiceEngineChoice) -> any RealtimeASREngine {
        let openAIKey = string("voice.openAIKey", fallback: "openAIKeyUser")
        let elevenLabsKey = string("voice.elevenLabsKey", fallback: "elevenLabsKeyUser")
        switch choice {
        case .vox:
            return VoxDictationEngine()
        case .tencent:
            return TencentRealtimeASRClient(
                appID: string("voice.tencentAppID", fallback: "tencentAppID"),
                secretID: string("voice.tencentSecretID", fallback: "tencentSecretID"),
                secretKey: string("voice.tencentSecretKey", fallback: "tencentSecretKey")
            )
        case .tencentSentence:
            return TencentSegmentedASRClient(
                secretID: string("voice.tencentSecretID", fallback: "tencentSecretID"),
                secretKey: string("voice.tencentSecretKey", fallback: "tencentSecretKey"),
                model: string("voice.tencentSentenceLanguage", fallback: "tencentSentenceLanguage") == "en"
                    ? "16k_en" : "16k_zh-PY"
            )
        case .elevenlabs:
            return ElevenLabsRealtimeASRClient(
                endpoint: elevenLabsRealtimeEndpoint, apiKey: elevenLabsKey, model: elevenLabsModel)
        case .elevenlabsBatch:
            return ElevenLabsTranscriptionClient(apiKey: elevenLabsKey, model: elevenLabsBatchModel)
        case .openai4o:
            return OpenAITranscriptionClient(apiKey: openAIKey, model: "gpt-4o-transcribe")
        case .openai4oMini:
            return OpenAITranscriptionClient(apiKey: openAIKey, model: "gpt-4o-mini-transcribe")
        case .openaiWhisper:
            return OpenAIRealtimeWhisperClient(apiKey: openAIKey)
        case .volc:
            return DoubaoRealtimeASRClient(
                endpoint: volcRealtimeEndpoint,
                appKey: string("voice.volcAppKey", fallback: "volcAppKey"),
                accessKey: string("voice.volcAccessKey", fallback: "volcAccessKey"),
                resourceID: volcRealtimeResourceId
            )
        }
    }
}
