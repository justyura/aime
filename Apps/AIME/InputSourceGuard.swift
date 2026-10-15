import AppKit
import Carbon

/// Keeps AIME selected when macOS falls back to a plain keyboard layout (U.S. / ABC).
///
/// AIME's input mode is not ASCII-capable, so password fields, authentication sheets and
/// some system UI make macOS switch to an ASCII layout, and it does not always switch
/// back. While secure input is on the layout is left alone (that is what it is for);
/// once it ends, AIME is selected again. Switching to another input *method* is never
/// undone. On by default; `defaults write app.zool.inputmethod.aime inputSource.keepSelected -bool false`
/// turns it off.
@MainActor
final class InputSourceGuard {
    static let shared = InputSourceGuard()

    private static let aimeModeID = "app.zool.inputmethod.aime.hans"
    private var observer: (any NSObjectProtocol)?
    private var retry: Timer?
    /// AIME was the last selected source, so a jump to a layout is a fallback to undo.
    private var aimeWasSelected = false

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "inputSource.keepSelected") as? Bool ?? true
    }

    func start() {
        aimeWasSelected = Self.currentID() == Self.aimeModeID
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { InputSourceGuard.shared.selectionChanged() }
        }
    }

    private func selectionChanged() {
        let current = Self.currentID()
        if current == Self.aimeModeID {
            aimeWasSelected = true
            stopRetry()
            return
        }
        guard isEnabled, aimeWasSelected, Self.currentIsKeyboardLayout() else {
            // The user picked another input method: respect it.
            aimeWasSelected = false
            stopRetry()
            return
        }
        DebugLog.write("input source fell back to \(current ?? "?"); secure=\(IsSecureEventInputEnabled())")
        scheduleRestore()
    }

    /// Restore shortly after the switch settles, and keep waiting while secure input
    /// (a password field) needs the ASCII layout.
    private func scheduleRestore() {
        stopRetry()
        retry = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { InputSourceGuard.shared.restoreIfPossible() }
        }
    }

    private func restoreIfPossible() {
        guard aimeWasSelected, Self.currentIsKeyboardLayout() else { return stopRetry() }
        guard !IsSecureEventInputEnabled() else { return }
        stopRetry()
        guard let source = Self.aimeSource() else { return }
        let status = TISSelectInputSource(source)
        DebugLog.write("input source restored to AIME status=\(status)")
    }

    private func stopRetry() {
        retry?.invalidate()
        retry = nil
    }

    private static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(source, kTISPropertyInputSourceID)
    }

    private static func currentIsKeyboardLayout() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return string(source, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String)
    }

    private static func aimeSource() -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: aimeModeID] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
        return list?.first
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
