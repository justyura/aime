@testable import AIMEVoice
import Testing

struct RightShiftTapTests {
    let shift: UInt = 1 << 17

    @Test func tapWithAndWithoutDeviceBits() {
        for flags in [shift | 0x4, shift, shift | (1 << 16) | (1 << 23)] {
            var tap = RightShiftTap()
            #expect(tap.handle(keyCode: 60, flags: flags, timestamp: 10) == .began)
            #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 10.1) == .triggered)
            #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 10.2) == .none)
        }
    }

    @Test func leftShiftAndChordsDoNotTrigger() {
        var tap = RightShiftTap()
        #expect(tap.handle(keyCode: 56, flags: shift | 0x2, timestamp: 1) == .none)
        #expect(tap.handle(keyCode: 56, flags: 0, timestamp: 1.1) == .none)
        #expect(tap.handle(keyCode: 60, flags: shift | (1 << 20), timestamp: 3) == .none)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 3.1) == .none)
    }

    @Test func holdTooLongOrKeyInBetweenCancels() {
        var tap = RightShiftTap()
        #expect(tap.handle(keyCode: 60, flags: shift | 0x4, timestamp: 4) == .began)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 5) == .cancelled)
        #expect(tap.handle(keyCode: 60, flags: shift | 0x4, timestamp: 6) == .began)
        let hadPress = tap.cancel() // a keyDown while held: Shift+letter
        #expect(hadPress)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 6.1) == .none)
    }

    @Test func otherModifierJoiningCancels() {
        var tap = RightShiftTap()
        #expect(tap.handle(keyCode: 60, flags: shift | 0x4, timestamp: 1) == .began)
        #expect(tap.handle(keyCode: 55, flags: shift | 0x4 | (1 << 20), timestamp: 1.1) == .cancelled)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 1.2) == .none)
    }

    /// The log of a real tap: press, release 85 ms later, then an echo pressed and
    /// released 4 ms apart. The echo must not count as a second tap.
    @Test func syntheticEchoAfterTapIsIgnored() {
        var tap = RightShiftTap()
        #expect(tap.handle(keyCode: 60, flags: shift, timestamp: 56.271) == .began)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 56.356) == .triggered)
        #expect(tap.handle(keyCode: 60, flags: shift, timestamp: 56.370) == .began)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 56.374) == .cancelled)
        // A deliberate second tap later still stops the dictation.
        #expect(tap.handle(keyCode: 60, flags: shift, timestamp: 58.0) == .began)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 58.08) == .triggered)
    }

    @Test func quickDoubleTapCountsOnce() {
        var tap = RightShiftTap()
        #expect(tap.handle(keyCode: 60, flags: shift, timestamp: 1.0) == .began)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 1.06) == .triggered)
        #expect(tap.handle(keyCode: 60, flags: shift, timestamp: 1.12) == .began)
        #expect(tap.handle(keyCode: 60, flags: 0, timestamp: 1.18) == .cancelled)
    }
}
