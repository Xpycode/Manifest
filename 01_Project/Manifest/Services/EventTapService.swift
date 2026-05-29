import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Wraps a `CGEventTap` listening for keys, mouse, and scroll events.
/// Yields `InputEvent`s through an `AsyncStream`. The view model drives the
/// stream and decides what to display / persist.
///
/// Pattern adapted from DownKeyCounter's EventTapService: the tap callback is
/// a C function trampoline; per-event work happens on the main run loop via
/// the trampoline calling `nonisolated` methods on the service.
@MainActor
final class EventTapService {
    enum TapError: Error, Sendable {
        case permissionDenied
        case tapCreationFailed
        case alreadyRunning
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility. Returns immediately; the
    /// system shows its TCC prompt and updates trust asynchronously.
    static func requestAccessibilityTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [key: kCFBooleanTrue] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // Run-loop-confined state. Reads/writes happen only from the C callback's
    // main-runloop hop, but Swift 6 strict concurrency can't see through the
    // trampoline — hence nonisolated(unsafe).
    private nonisolated(unsafe) var continuation: AsyncStream<InputEvent>.Continuation?
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var source: CFRunLoopSource?
    private nonisolated(unsafe) var lastFlags: CGEventFlags = []

    /// Belt-and-suspenders recovery for the "keyboard stopped registering in
    /// the app but still works everywhere else" bug. The system can disable a
    /// `.listenOnly` tap (a callback ran too long, or a security setting
    /// toggled). The in-callback re-enable in `handle(type:event:)` only fires
    /// if *another* event arrives — but a wedged tap delivers nothing, so
    /// nothing triggers recovery. This timer polls `CGEvent.tapIsEnabled` on
    /// the main run loop, independently of the callback, and re-enables a dead
    /// tap. Scheduled in `.common` mode so it survives modal/tracking loops.
    private var watchdog: Timer?

    private nonisolated let monitor: FrontmostAppMonitor

    private nonisolated static let modifierMask: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn
    ]

    init(monitor: FrontmostAppMonitor) {
        self.monitor = monitor
    }

    /// Creates the tap and returns the event stream. Caller owns the stream's
    /// consumer task; calling `stop()` finishes the stream.
    func start() throws -> AsyncStream<InputEvent> {
        guard Self.isAccessibilityTrusted else { throw TapError.permissionDenied }
        guard tap == nil else { throw TapError.alreadyRunning }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let machPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            throw TapError.tapCreationFailed
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)

        self.tap = machPort
        self.source = runLoopSource
        self.lastFlags = []

        // Poll every 2 s on the main run loop (same loop the tap callback runs
        // on, so reading the run-loop-confined `tap` stays consistent).
        let watchdog = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.watchdogCheck()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog

        let stream = AsyncStream<InputEvent> { continuation in
            self.continuation = continuation
        }
        return stream
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        continuation?.finish()
        continuation = nil
        lastFlags = []
    }

    /// Externally-callable: emit an `.appSwitch` row from the FrontmostAppMonitor.
    nonisolated func emitAppSwitch(from previousID: String?, to nextID: String?) {
        let fromName = previousID ?? "?"
        let toName = nextID ?? "?"
        let row = InputEvent(
            kind: .appSwitch,
            label: "Switched: \(fromName) → \(toName)",
            bundleID: nextID,
            appName: nil
        )
        continuation?.yield(row)
    }

    fileprivate nonisolated func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system disabled our tap — usually because a callback ran too
            // long (timeout) or the user toggled a security setting. Re-enable
            // and log it: this is the single most useful signal when a user
            // reports "it stopped capturing for no reason."
            DiagnosticLogger.shared.log(
                "event tap disabled by system, re-enabling",
                level: .warn,
                state: ["reason": type == .tapDisabledByTimeout ? "timeout" : "userInput"]
            )
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        // Don't capture events the OS is routing to a secure input field
        // (passwords, etc.). This catches the common cases without us having
        // to inspect each row individually.
        if IsSecureEventInputEnabled() && type == .keyDown {
            return
        }

        let frontmost = monitor.currentBundleID

        switch type {
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let label = KeyNameMapper.label(forKeyCode: keyCode, modifiers: event.flags)
            yield(InputEvent(kind: .key, label: label, bundleID: frontmost))

        case .flagsChanged:
            // Track tap-style modifier press/releases (Cmd alone, etc.) so
            // Cmd+Tab still produces a "Cmd" row even when the Tab keyDown is
            // swallowed by the system shortcut.
            let current = event.flags.intersection(Self.modifierMask)
            let pressed = current.subtracting(lastFlags)
            lastFlags = current
            if !pressed.isEmpty, let label = singleModifierLabel(in: pressed) {
                yield(InputEvent(kind: .modifier, label: label, bundleID: frontmost))
            }

        case .leftMouseDown:
            yield(InputEvent(kind: .mouse, label: "Left Click",
                             bundleID: frontmost, point: event.location))

        case .rightMouseDown:
            yield(InputEvent(kind: .mouse, label: "Right Click",
                             bundleID: frontmost, point: event.location))

        case .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            yield(InputEvent(kind: .mouse, label: "Mouse \(button + 1)",
                             bundleID: frontmost, point: event.location))

        case .scrollWheel:
            let dy = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let dx = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            guard dx != 0 || dy != 0 else { return }
            let label = scrollLabel(dx: dx, dy: dy)
            yield(InputEvent(kind: .scroll, label: label, bundleID: frontmost,
                             scrollDelta: ScrollDelta(dx: dx, dy: dy)))

        default:
            break
        }
    }

    /// Runs on the main run loop (the timer is scheduled there). Reads the
    /// run-loop-confined `tap` and re-enables it if the system silently
    /// disabled it. Logs only on an actual recovery, so the diagnostic log
    /// isn't spammed every 2 s during normal operation.
    private nonisolated func watchdogCheck() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        DiagnosticLogger.shared.log(
            "watchdog re-enabled event tap (was disabled with no event to trigger in-callback recovery)",
            level: .warn
        )
    }

    private nonisolated func yield(_ event: InputEvent) {
        continuation?.yield(event)
    }

    private nonisolated func singleModifierLabel(in flags: CGEventFlags) -> String? {
        for candidate in [CGEventFlags.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn] {
            if flags.contains(candidate) {
                return KeyNameMapper.modifierOnlyLabel(for: candidate)
            }
        }
        return nil
    }

    private nonisolated func scrollLabel(dx: Int, dy: Int) -> String {
        // Arrows show direction; numbers show magnitude. macOS's "natural"
        // scrolling means dy > 0 = scroll content up = finger swipes down.
        var parts: [String] = []
        if dy != 0 {
            parts.append("\(dy > 0 ? "↑" : "↓") \(abs(dy))")
        }
        if dx != 0 {
            parts.append("\(dx > 0 ? "→" : "←") \(abs(dx))")
        }
        return "Scroll " + parts.joined(separator: " ")
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let service = Unmanaged<EventTapService>.fromOpaque(userInfo).takeUnretainedValue()
        service.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
