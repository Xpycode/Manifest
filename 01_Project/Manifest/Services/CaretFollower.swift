import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Tracks the text caret of the focused element in the frontmost app via AX.
///
/// Three-tier fallback (decided in `docs/specs/placement.md` §4):
///   1. Caret rect via `kAXBoundsForRangeParameterizedAttribute` (length = 1).
///   2. Focused-element frame via `kAXPositionAttribute` + `kAXSizeAttribute`.
///   3. Freeze in place.
///
/// Event-driven, not polled: `AXObserver` on `kAXSelectedTextChangedNotification`
/// and `kAXFocusedUIElementChangedNotification` triggers a refresh. Observers
/// are rebound when the frontmost app changes (caller drives this via
/// `frontmostAppChanged(pid:)`).
///
/// Threading mirrors `AXElementLookup`: AX calls are synchronous IPC and live
/// on a private serial queue with a 250 ms `AXUIElementSetMessagingTimeout`
/// per element. Results post back to main and call `onResult`.
@MainActor
final class CaretFollower {

    enum Tier: Equatable, Sendable {
        case caret              // got caret rect
        case fieldRect          // fell back to focused-element frame
        case frozen             // both tiers failed → hold last position
    }

    struct Result: Sendable, Equatable {
        /// CG-space, top-left origin. The point fed to `PlacementMath.placeHUD`
        /// as `anchor`. For caret/field tiers it's the bottom-left of the
        /// returned rect (so dy=24 puts the HUD 24pt below the line of text).
        let anchorCG: CGPoint
        let tier: Tier
        /// PID of the frontmost app at the time of the read.
        let pid: pid_t
        /// True iff (pid, tier) differs from the previously delivered Result.
        /// Lets the caller fire a one-shot status message exactly on
        /// transitions (app-switch or tier change within an app) without
        /// re-doing the bookkeeping itself. See `docs/specs/placement.md` §12.
        let tierChanged: Bool
    }

    /// Posted on the main actor whenever a refresh completes — including the
    /// `frozen` tier (so the caller knows to surface the status message).
    /// For `frozen`, `anchorCG` is the last successful anchor or `.zero` if
    /// nothing has ever resolved.
    var onResult: ((Result) -> Void)?

    // AX I/O happens on this serial queue. Never call AX from MainActor —
    // a hung target would block UI for up to the messaging-timeout window.
    private let axQueue = DispatchQueue(label: "showinputs.caret", qos: .userInitiated)

    // All four are accessed on the main run loop only. The observer callback
    // runs on whichever run loop its source was added to (main, here).
    private var currentPID: pid_t?
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var focusedElement: AXUIElement?

    // Coalesce observer fires so a 200 Hz keystroke storm in apps that fire
    // selected-text-changed per glyph doesn't pin a CPU.
    private var refreshScheduled = false
    private static let coalesceWindow: TimeInterval = 0.016

    // Last successful anchor (for the `frozen` tier's published point).
    private var lastAnchor: CGPoint = .zero

    // (pid, tier) of the last delivered Result. Used to compute `tierChanged`
    // so the controller can fire status messages once per transition rather
    // than on every observer event (which can fire per glyph in fast typing).
    private var lastDeliveredTier: (pid: pid_t, tier: Tier)?

    /// Bind the caret observer to the given PID. Tearing down any previous
    /// observer first. Pass nil (or the same PID twice) to no-op.
    func frontmostAppChanged(pid: pid_t?) {
        if pid == currentPID { return }
        tearDownObserver()
        currentPID = pid
        // PID changed → next delivery is by definition a transition. Clearing
        // here makes the intent explicit even though the (pid != lastPid)
        // check in `didTransition` would already catch it.
        lastDeliveredTier = nil
        guard let pid, pid > 0 else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        self.appElement = app
        installObserver(pid: pid, app: app)
        scheduleRefresh()
    }

    /// Force the next delivered `Result` to carry `tierChanged = true`, then
    /// kick off an immediate refresh. Use this when re-engaging follow-caret
    /// mode while the frontmost app hasn't changed — `frontmostAppChanged`
    /// early-outs on the same-PID case, so without this the caller might wait
    /// arbitrarily long for the next AX observer event before getting a
    /// status-message-worthy delivery.
    func forceTransitionOnNextDelivery() {
        lastDeliveredTier = nil
        scheduleRefresh()
    }

    func start() {
        // Bind to whichever app is currently frontmost.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            frontmostAppChanged(pid: pid)
        }
    }

    func stop() {
        tearDownObserver()
        currentPID = nil
        appElement = nil
        focusedElement = nil
        lastAnchor = .zero
        lastDeliveredTier = nil
        refreshScheduled = false
    }

    // MARK: - Observer plumbing

    private func installObserver(pid: pid_t, app: AXUIElement) {
        var newObserver: AXObserver?
        let createErr = AXObserverCreate(pid, caretObserverCallback, &newObserver)
        guard createErr == .success, let obs = newObserver else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Notifications on the app element catch focus shifts to a new
        // element; per-element notifications (selected text changed) are
        // installed each time the focused element rotates.
        AXObserverAddNotification(obs, app, kAXFocusedUIElementChangedNotification as CFString, refcon)

        let source = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.observer = obs
    }

    private func tearDownObserver() {
        if let observer {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            if let focusedElement {
                AXObserverRemoveNotification(observer, focusedElement, kAXSelectedTextChangedNotification as CFString)
            }
            if let appElement {
                AXObserverRemoveNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString)
            }
        }
        observer = nil
        focusedElement = nil
    }

    /// Called from the C trampoline on the main run loop.
    fileprivate nonisolated func observerFired() {
        MainActor.assumeIsolated {
            self.scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.kickOffAXRead()
        }
    }

    // MARK: - AX read (off-main)

    private func kickOffAXRead() {
        guard let app = appElement, let pid = currentPID else { return }
        let lastAnchor = self.lastAnchor

        // Secure input is a privacy gate: if any app holds secure input
        // (typically a password field), the user is not interactive in a
        // text field we should reveal positions for. Freeze and bail.
        if IsSecureEventInputEnabled() {
            deliver(anchor: lastAnchor, tier: .frozen, pid: pid)
            return
        }

        axQueue.async { [weak self] in
            let read = Self.readAnchor(app: app, pid: pid, lastAnchor: lastAnchor)
            DispatchQueue.main.async {
                // We're on the main thread; assume MainActor so we can touch
                // self's @MainActor-isolated state without a Task hop.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.focusedElement = read.focused
                    self.rebindFocusedElementNotifications()
                    if read.tier != .frozen {
                        self.lastAnchor = read.anchorCG
                    }
                    self.deliver(anchor: read.anchorCG, tier: read.tier, pid: pid)
                }
            }
        }
    }

    private func rebindFocusedElementNotifications() {
        guard let observer, let focusedElement else { return }
        // Re-add is idempotent (returns success or "already-registered"); we
        // don't strip the prior binding because we don't track which element
        // it was on, but AX will return notFound on a dead element which is
        // harmless.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, focusedElement, kAXSelectedTextChangedNotification as CFString, refcon)
    }

    private func deliver(anchor: CGPoint, tier: Tier, pid: pid_t) {
        let changed = Self.didTransition(previous: lastDeliveredTier, currentPID: pid, currentTier: tier)
        lastDeliveredTier = (pid, tier)
        onResult?(Result(anchorCG: anchor, tier: tier, pid: pid, tierChanged: changed))
    }

    /// Pure dedup predicate, factored out so it's unit-testable without
    /// standing up a live AX observer.
    /// - Returns: `true` iff `previous` is nil or differs in pid or tier.
    nonisolated static func didTransition(
        previous: (pid: pid_t, tier: Tier)?,
        currentPID: pid_t,
        currentTier: Tier
    ) -> Bool {
        guard let previous else { return true }
        return previous.pid != currentPID || previous.tier != currentTier
    }

    // MARK: - Pure AX read

    private struct ReadResult {
        let anchorCG: CGPoint
        let tier: Tier
        let focused: AXUIElement?
    }

    /// Synchronous AX read. Called on `axQueue`. Returns the new anchor (or a
    /// frozen result holding the prior anchor) plus the resolved focused
    /// element for the caller to install a notification on.
    nonisolated private static func readAnchor(app: AXUIElement, pid: pid_t, lastAnchor: CGPoint) -> ReadResult {
        // Resolve focused element. `kAXFocusedUIElementAttribute` on the app
        // element returns the leaf-most focused element across the app's
        // window hierarchy.
        var focusedRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusedErr == .success, let unwrapped = focusedRef else {
            return ReadResult(anchorCG: lastAnchor, tier: .frozen, focused: nil)
        }
        let focused = unwrapped as! AXUIElement

        AXUIElementSetMessagingTimeout(focused, 0.10)

        // Secure-text-field subrole gate (a focused password field).
        if let subrole = readString(focused, kAXSubroleAttribute), subrole == "AXSecureTextField" {
            return ReadResult(anchorCG: lastAnchor, tier: .frozen, focused: focused)
        }

        // Tier 1: caret rect via parameterized bounds. Length = 1 (not 0) —
        // many apps return a degenerate rect for length=0.
        if let rect = caretRect(focused: focused) {
            // Anchor at bottom-left of the rect: in CG space, bottom is maxY.
            let anchor = CGPoint(x: rect.minX, y: rect.maxY)
            return ReadResult(anchorCG: anchor, tier: .caret, focused: focused)
        }

        // Tier 2: focused-element frame.
        if let rect = elementFrame(focused: focused) {
            let anchor = CGPoint(x: rect.minX, y: rect.maxY)
            return ReadResult(anchorCG: anchor, tier: .fieldRect, focused: focused)
        }

        // Tier 3: freeze.
        return ReadResult(anchorCG: lastAnchor, tier: .frozen, focused: focused)
    }

    nonisolated private static func caretRect(focused: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeErr == .success, let rangeRaw = rangeRef else { return nil }
        let axRange = rangeRaw as! AXValue
        var cfRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &cfRange) else { return nil }

        // Use length=1 at the insertion point; many apps return a zero rect
        // for length=0. If the selection has actual length, query the first
        // char of the selection so we anchor at the selection start.
        var probe = CFRange(location: cfRange.location, length: 1)
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return nil }

        var boundsRef: CFTypeRef?
        let boundsErr = AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            probeValue,
            &boundsRef
        )
        guard boundsErr == .success, let boundsRaw = boundsRef else { return nil }
        let axBounds = boundsRaw as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else { return nil }
        // Some backends return a CGRect with zero size or off-screen junk
        // (e.g. y = -9800 for web fields without VoiceOver). Reject those.
        if rect.width <= 0 || rect.height <= 0 { return nil }
        if rect.origin.y < -1_000 { return nil }
        return rect
    }

    nonisolated private static func elementFrame(focused: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &posRef)
        let sizeErr = AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeRef)
        guard posErr == .success, sizeErr == .success,
              let posRaw = posRef, let sizeRaw = sizeRef else { return nil }
        let posValue = posRaw as! AXValue
        let sizeValue = sizeRaw as! AXValue
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        if size.width <= 0 || size.height <= 0 { return nil }
        return CGRect(origin: pos, size: size)
    }

    nonisolated private static func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }
}

/// C trampoline for `AXObserverCreate`. Hops back into the Swift class via
/// the refcon pointer. The notification name and element are unused — we just
/// schedule a refresh on every fire and let the read decide what changed.
private func caretObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let follower = Unmanaged<CaretFollower>.fromOpaque(refcon).takeUnretainedValue()
    follower.observerFired()
}
