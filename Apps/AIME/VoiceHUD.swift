import AppKit

/// Small floating bubble for voice input, separate from the candidate panel so the two
/// can be on screen together: dictating while typing pinyin keeps the candidates below
/// the cursor and the transcript above it.
@MainActor
final class VoiceHUD {
    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let closeButton = FirstClickButton()
    private let closeTarget = CloseTarget()
    /// The × was clicked: cancel the dictation and close the bubble.
    var onClose: (() -> Void)? {
        get { closeTarget.action }
        set { closeTarget.action = newValue }
    }
    private static let maxWidth: CGFloat = 520
    private static let maxCharacters = 80

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Only the × takes clicks; the panel never activates, so focus stays in the app.
        window.ignoresMouseEvents = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭语音输入")
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "取消语音输入"
        closeButton.target = closeTarget
        closeButton.action = #selector(CloseTarget.fire)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        background.addSubview(closeButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        window.contentView = background
    }

    /// Shows `text` just above the caret line (`cursorRect`, screen coordinates).
    func show(_ text: String, near cursorRect: NSRect) {
        // Keep the newest words: the bubble is a live tail, not the whole transcript.
        let tail = text.count > Self.maxCharacters ? "…" + text.suffix(Self.maxCharacters) : text
        label.stringValue = tail
        let width = min(Self.maxWidth, ceil(label.intrinsicContentSize.width) + 10 + 6 + 16 + 7)
        let height: CGFloat = 28
        var origin: NSPoint
        if cursorRect == .zero, let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 80)
        } else {
            origin = NSPoint(x: cursorRect.minX, y: cursorRect.maxY + 6)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorRect.origin) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = max(frame.minX + 4, min(origin.x, frame.maxX - width - 4))
            if origin.y + height > frame.maxY { origin.y = cursorRect.minY - height - 30 }
        }
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

/// Target for the × button (NSButton needs an Objective-C target).
@MainActor
private final class CloseTarget: NSObject {
    var action: (() -> Void)?
    @objc func fire() { action?() }
}

/// The bubble belongs to a background process and never becomes key: the button has to
/// act on the very first click instead of spending it on activating the window.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
