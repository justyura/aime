import Foundation

/// Recognizes a lone tap of Right Shift from IMK `flagsChanged` events: press with no
/// other modifier, release within 0.6 s, and no key in between (call `cancel()` on any
/// keyDown). Works on keyboards that omit the left/right device bits.
///
/// Some setups echo a tap as a second, synthetic press + release a few ms apart. A press
/// shorter than `minimumHold` is not a human tap, and a tap within `debounce` of the
/// previous one is ignored; otherwise the echo would stop a dictation it just started.
public struct RightShiftTap: Sendable {
    public enum Event: Equatable, Sendable { case none, began, triggered, cancelled }

    public static let keyCode: UInt16 = 60
    static let shift: UInt = 1 << 17
    static let plainModifiers: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) // ⇧ ⌃ ⌥ ⌘
    static let rightShiftDevice: UInt = 0x0004
    static let shiftDevices: UInt = 0x0006
    static let window: ClosedRange<TimeInterval> = 0...0.6
    static let minimumHold: TimeInterval = 0.015
    static let debounce: TimeInterval = 0.3

    private var pressedAt: TimeInterval?
    private var lastTriggerAt: TimeInterval?

    public init() {}

    public var isPressed: Bool { pressedAt != nil }

    /// Forget a press in progress; true when one was pending.
    @discardableResult
    public mutating func cancel() -> Bool {
        defer { pressedAt = nil }
        return pressedAt != nil
    }

    public mutating func handle(keyCode: UInt16, flags: UInt, timestamp: TimeInterval) -> Event {
        guard keyCode == Self.keyCode else { return cancel() ? .cancelled : .none }
        let plain = flags & Self.plainModifiers
        let down = flags & Self.rightShiftDevice != 0
            || (flags & Self.shiftDevices == 0 && flags & Self.shift != 0)
        if down {
            guard plain == Self.shift else { return cancel() ? .cancelled : .none }
            guard pressedAt == nil else { return .none }
            pressedAt = timestamp
            return .began
        }
        guard let pressedAt else { return .none }
        self.pressedAt = nil
        let held = timestamp - pressedAt
        guard plain == 0, Self.window.contains(held) else { return .cancelled }
        guard held >= Self.minimumHold else { return .cancelled }
        if let last = lastTriggerAt, timestamp - last < Self.debounce { return .cancelled }
        lastTriggerAt = timestamp
        return .triggered
    }
}
