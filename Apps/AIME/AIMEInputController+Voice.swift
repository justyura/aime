import AIMEPanel
import AIMEVoice
import AppKit
import InputMethodKit

/// 语音输入: a lone tap of Right Shift starts dictation, another tap stops it.
///
/// While speaking, partial transcripts are shown as marked text at the cursor (the app
/// sees one composition being revised, not keystrokes being retyped); the final text is
/// committed with insertText. Esc cancels. Enabled with
/// `defaults write app.zool.inputmethod.aime voice.enabled -bool true`.
extension AIMEInputController {
    private var voice: VoiceDictation { InputEngine.shared.voice }

    /// The controller whose field receives the dictation.
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
            case .idle: startVoice(client: client)
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

    /// Keys while dictating: Esc cancels, Return stops, anything else stops too (the key
    /// itself is swallowed so it cannot land in the middle of the transcript).
    func handleVoiceKey(_ event: NSEvent) -> Bool {
        let engine = InputEngine.shared
        if engine.voiceTap.cancel(), !voice.isActive { voice.cancelPrepared() } // Shift+key: a chord, not a tap
        guard voice.isActive, ownsVoice else { return false }
        if event.keyCode == 53 { // Esc
            voice.cancel()
            endVoice()
            engine.showStatus("已取消语音输入")
            return true
        }
        if voice.state == .recording { voice.stop() }
        return true
    }

    /// Leaving the field while dictating: stop listening; the transcript still arrives
    /// and goes to whichever field is active by then.
    func voiceDeactivated() {
        guard ownsVoice, voice.state == .recording else { return }
        voice.stop()
    }

    private func startVoice(client: (any IMKTextInput)?) {
        let engine = InputEngine.shared
        // Whatever is being typed goes in first, so speech continues after it.
        commitPending(client)
        engine.voiceController = self
        voice.onPartial = { [weak self] text in self?.showVoicePartial(text) }
        voice.onStateChange = { [weak self] state in self?.showVoiceStatus(state) }
        voice.onNotice = { message in InputEngine.shared.showStatus(message) }
        voice.onFinal = { [weak self] text in self?.deliverVoice(text) }
        voice.start()
    }

    private func showVoiceStatus(_ state: VoiceDictation.State) {
        let engine = InputEngine.shared
        switch state {
        case .recording:
            engine.cancelStatus()
            var status = PanelState(status: "右⇧ 结束   Esc 取消")
            status.statusBadge = "🎙"
            engine.panel.show(status, at: cursorRect(client: textClient))
        case .finishing:
            var status = PanelState(status: "\(voice.activeEngine.displayName) 转写中…")
            status.statusBadge = "🎙"
            engine.panel.show(status, at: cursorRect(client: textClient))
        case .idle:
            break
        }
    }

    private func showVoicePartial(_ text: String) {
        guard ownsVoice, let client = textClient else { return }
        let length = (text as NSString).length
        client.setMarkedText(markedText(text, converted: length, selectedEnd: length),
                             selectionRange: NSRange(location: length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = true
    }

    private func deliverVoice(_ text: String) {
        let engine = InputEngine.shared
        // The field may have changed meanwhile: deliver to the active one.
        let target = engine.activeController ?? self
        if ownsVoice, target !== self, hasMarkedText {
            textClient?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = false
        }
        endVoice()
        guard !text.isEmpty else {
            target.clearVoiceMarkedText()
            return
        }
        guard let client = target.textClient else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            engine.showStatus("没有可输入的位置，转写结果已复制")
            return
        }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        target.hasMarkedText = false
        target.recentText.append(text) // AI actions (长按 ⌥) can work on what was just said
        engine.usage.record(text, app: target.bundleID)
    }

    private func clearVoiceMarkedText() {
        guard hasMarkedText, liveSession.map({ !$0.context().isComposing }) ?? true else { return }
        textClient?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = false
    }

    private func endVoice() {
        let engine = InputEngine.shared
        if ownsVoice {
            clearVoiceMarkedText()
            engine.voiceController = nil
        }
        if engine.activeController?.ownsPanel == true { engine.activeController?.restorePanelAfterStatus() }
        else { engine.panel.hide() }
    }
}
