import AIMEVoice
import AppKit
import InputMethodKit

/// 语音输入: a lone tap of Right Shift starts dictation, another tap stops it.
///
/// Dictation and typing run side by side: keys keep going to librime and the app while
/// listening, the live transcript shows in a bubble above the cursor (not as marked text,
/// which belongs to the pinyin composition), and the final text is inserted at the cursor
/// once nothing is being composed. Esc cancels when no composition would claim it.
/// Enabled with `defaults write app.zool.inputmethod.aime voice.enabled -bool true`.
extension AIMEInputController {
    private var voice: VoiceDictation { InputEngine.shared.voice }

    /// The controller whose field started the dictation.
    private var ownsVoice: Bool { InputEngine.shared.voiceController === self }

    /// Right Shift transitions. True when the event belongs to voice input and must not
    /// reach librime (Right Shift is meant for dictation, not 中/英).
    func handleVoiceFlags(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        guard VoiceSettings.isEnabled else { return false }
        let engine = InputEngine.shared
        let result = engine.voiceTap.handle(keyCode: event.keyCode, flags: event.modifierFlags.rawValue,
                                            timestamp: event.timestamp)
        switch result {
        case .began:
            if !voice.isActive { voice.prepare() }
        case .triggered:
            switch voice.state {
            case .idle: startVoice()
            case .recording: voice.stop()
            case .finishing: break
            }
        case .cancelled:
            if !voice.isActive { voice.cancelPrepared() }
        case .none:
            break
        }
        return event.keyCode == RightShiftTap.keyCode
    }

    /// Keys never stop a dictation: they go on to librime as usual. Only Esc with nothing
    /// being composed cancels it (with a composition, Esc clears that instead).
    func handleVoiceKey(_ event: NSEvent) -> Bool {
        let engine = InputEngine.shared
        if engine.voiceTap.cancel(), !voice.isActive { voice.cancelPrepared() } // Shift+key: a chord, not a tap
        guard voice.isActive, event.keyCode == 53, !isComposing, draft.isEmpty else { return false }
        voice.cancel()
        engine.pendingVoiceText = nil
        engine.voiceController = nil
        engine.voiceHUD.hide()
        engine.showStatus("已取消语音输入")
        return true
    }

    /// Leaving the field while dictating: stop listening; the transcript still arrives
    /// and goes to whichever field is active by then.
    func voiceDeactivated() {
        guard ownsVoice, voice.state == .recording else { return }
        voice.stop()
    }

    private func startVoice() {
        let engine = InputEngine.shared
        engine.voiceController = self
        engine.pendingVoiceText = nil
        voice.onPartial = { text in InputEngine.shared.showVoiceBubble("🎙 " + text) }
        voice.onStateChange = { state in
            let engine = InputEngine.shared
            switch state {
            case .recording: engine.showVoiceBubble("🎙 聆听中…  右⇧ 结束")
            case .finishing: engine.showVoiceBubble("🎙 \(engine.voice.activeEngine.displayName) 转写中…")
            case .idle: break
            }
        }
        voice.onNotice = { message in InputEngine.shared.showStatus(message) }
        voice.onFinal = { text in
            let engine = InputEngine.shared
            engine.voiceController = nil
            guard !text.isEmpty else { return engine.voiceHUD.hide() }
            engine.pendingVoiceText = text
            (engine.activeController)?.flushPendingVoice(client: nil) ?? engine.deliverVoiceWithoutField()
        }
        voice.start()
    }

    /// Inserts a finished transcript once the field is free: nothing being composed. Called
    /// when it arrives and after every key, so it lands right after the pinyin you were
    /// typing is committed.
    func flushPendingVoice(client: (any IMKTextInput)?) {
        let engine = InputEngine.shared
        guard let text = engine.pendingVoiceText else { return }
        guard !isComposing else {
            engine.showVoiceBubble("🎙 打完当前拼音后插入：" + text)
            return
        }
        guard let client = client ?? textClient else { return }
        engine.pendingVoiceText = nil
        engine.voiceHUD.hide()
        if !draft.isEmpty { flushDraft(client: client) }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        recentText.append(text) // AI actions (长按 ⌥) can work on what was just said
        engine.usage.record(text, app: bundleID)
    }
}

extension InputEngine {
    func showVoiceBubble(_ text: String) {
        voiceHUD.show(text, near: activeController?.cursorRect() ?? .zero)
    }

    /// No field to type into: keep the transcript on the clipboard instead of losing it.
    func deliverVoiceWithoutField() {
        guard let text = pendingVoiceText else { return }
        pendingVoiceText = nil
        voiceHUD.hide()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showStatus("没有可输入的位置，转写结果已复制")
    }
}
