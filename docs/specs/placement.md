# Spec — User-Definable Panel Distance from Pointer / Caret

**Status:** Draft (2026-05-28) — not yet implemented.
**Owner:** see `docs/PROJECT_STATE.md`.
**Source research:** dispatched general-purpose agent (Apple AX docs, CursorBounds reference impl, AXSwift, TN2150) + Plan agent on the live codebase. Reconciled below.

Today the HUD is a drag-positioned `NSPanel` whose origin persists in `UserDefaults` as `hud.frame.originX/Y` (`FloatingPanel.swift:20-21, 77-99`). There is no following behavior. This spec adds three placement modes plus a user-definable offset, all live-editable, without disturbing the existing pinned-drag flow.

---

## 1. Modes & data model

```swift
enum PanelPlacement: String, Codable, CaseIterable {
    case pinned          // current behavior: user drag, origin persisted
    case followPointer   // HUD tracks NSEvent.mouseLocation
    case followCaret     // HUD tracks the text caret of the focused field
}

struct PanelOffset: Codable, Equatable {
    var dx: CGFloat       // points, signed (+x = HUD right of anchor)
    var dy: CGFloat       // points, signed (+y = HUD below anchor, CG convention)
    var flipNearEdges: Bool
}
```

**Why signed dx/dy, not anchor-corner enum:** the sign of the offset already encodes which corner of the HUD anchors to the cursor/caret. Edge-flip becomes `dx = -dx` instead of "swap enum case". Two `Stepper`s in the UI, not a corner picker + dx + dy.

**Defaults:** `dx = 24, dy = 24` (below-right of the anchor, clears the ~16 pt cursor hot-spot). Range `−200…+200` pt, step 4. `flipNearEdges = true`.

The HUD's own size enters the math but doesn't enter the model — read it from the live `NSPanel.frame.size` at apply-time so compact↔expanded transitions Just Work.

## 2. Architecture (mirrors existing "services own work, VM owns state, view is dumb")

```
EventStreamViewModel  (@Observable, @MainActor)
  ├── placementMode: PanelPlacement      ── persisted to UserDefaults
  └── placementOffset: PanelOffset        ── persisted to UserDefaults

PanelPlacementController   (new, @MainActor)
  ├── owns: PointerFollower, CaretFollower, suspension state
  ├── observes: vm.placementMode / placementOffset
  └── applies: applyTargetOrigin(_:) → panel.setFrameOrigin(...)

PointerFollower            (new) — CADisplayLink + NSEvent.mouseLocation
CaretFollower              (new) — AXObserver + kAXBoundsForRangeParameterizedAttribute
PlacementMath              (new, pure) — applyOffset, clamp, flip, CG↔AppKit
```

Public surface of the controller:

```swift
@MainActor final class PanelPlacementController {
    init(panel: FloatingPanel, vm: EventStreamViewModel, monitor: FrontmostAppMonitor)
    func start(); func stop()
    func userDidDrag()                       // called from FloatingPanel.mouseDown
    func frontmostAppChanged(pid: pid_t?)    // CaretFollower rebinds AXObserver
}
```

## 3. Pointer follow

**`CADisplayLink` reading `NSEvent.mouseLocation`** (macOS 14+; we target 15+). Pause-on-display-sleep is free.

- Callback fires once per refresh (60 or 120 Hz, harmless either way).
- `NSEvent.mouseLocation` is documented safe off-main, but `setFrameOrigin` is not — hop to `MainActor` only when the new origin differs from last applied by ≥ 0.5 pt.
- **No new permission, no event tap traffic.**

Rejected alternatives:
- Extending `EventTapService` with `.mouseMoved`: floods the listenOnly tap (~1000+ events/sec on trackpad gestures); the tap is explicitly scoped to key/click/scroll in CLAUDE.md.
- `Timer` at 16 ms: free-runs even on display sleep.
- `addGlobalMonitorForEvents(.mouseMoved)`: may prompt Input Monitoring, can't see events while Secure Input is on.

## 4. Caret follow

Recipe (Apple `kAXBoundsForRangeParameterizedAttribute` docs + CursorBounds reference impl):

1. `AXUIElementCreateApplication(frontmostPID)` → app element.
2. `AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused)`.
3. `AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute, &cfRange)`.
4. Build an `AXValue` wrapping `CFRange(location: cfRange.location, length: 1)` — **length=1, not 0**; many apps return a degenerate rect for length=0.
5. `AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute, axRange, &bounds)` → `CGRect` in screen points, top-left origin.

**Observer (event-driven, not polled):** `AXObserver` on the focused app for `kAXSelectedTextChangedNotification` + `kAXFocusedUIElementChangedNotification`. Run-loop source added to main with `.commonModes`. Coalesce observer fires through a 16 ms debounce to absorb per-keystroke notifications.

**Rebind on app switch:** hook `FrontmostAppMonitor` (the existing service powering `.appSwitch` rows). Tear down the old observer, create a new one for the new PID.

**Threading:** AX calls are synchronous IPC. Mirror the `AXElementLookup.swift` pattern — dedicated serial `DispatchQueue(qos: .userInitiated)`, `AXUIElementSetMessagingTimeout(focused, 0.1)`. **Do NOT use `Task.detached`** — Apple forum #802423 documents cooperative-pool starvation when AX IPC blocks.

**Fallback chain** (caret → focused-field rect → freeze; not to pointer):

1. **Caret rect** via `kAXBoundsForRangeParameterizedAttribute` (steps 1-5 above). Anchor = bottom-left of the returned `CGRect`.
2. **Focused-field rect.** If step 5 returns `kAXErrorAttributeUnsupported` / `kAXErrorCannotComplete` / a zero rect, read `kAXPositionAttribute` (CGPoint) + `kAXSizeAttribute` (CGSize) on the same focused element. Compose into a CGRect; anchor = bottom-left. Set `vm.statusMessage = "Caret bounds unavailable — docking to text field."` once per app-switch. This works in many Electron apps that hide per-character bounds but still expose the editor element's frame.
3. **Freeze.** If even step 2 fails (no position/size, or focused element resolution itself failed), hold the HUD's last applied origin. Set `vm.statusMessage = "No text position info — HUD held in place."` once per app-switch.

**Why not fall back to pointer:** the user explicitly picked `followCaret` because they want the HUD near where text is going. The pointer is usually parked far from the typing area while typing — silently teleporting the HUD to it would violate intent. Pointer-follow is a separate mode the user can pick.

**Known-flaky apps to document in the Settings view:** Electron (VS Code, Slack, Cursor, Notion), Terminal/iTerm/Ghostty, web text inputs in Chrome/Safari/Firefox (unless VoiceOver is on), JetBrains IDEs.

## 5. Placement math (pure, in `PlacementMath.swift`)

```
let hud = panel.frame.size
let screen = NSScreen.containing(anchorCG)?.visibleFrame ?? .main.visibleFrame
let cgScreen = appKitFrameToCG(screen)
var (dx, dy) = (offset.dx, offset.dy)
var topLeft = CGPoint(x: anchorCG.x + dx, y: anchorCG.y + dy)

if offset.flipNearEdges {
    if dx >= 0, topLeft.x + hud.width  > cgScreen.maxX { dx = -dx - hud.width  }
    if dy >= 0, topLeft.y + hud.height > cgScreen.maxY { dy = -dy - hud.height }
    if dx <  0, topLeft.x              < cgScreen.minX { dx = -dx }
    if dy <  0, topLeft.y              < cgScreen.minY { dy = -dy }
    topLeft = CGPoint(x: anchorCG.x + dx, y: anchorCG.y + dy)
}
// Hard-clamp safety net regardless of flip toggle
topLeft.x = clamp(topLeft.x, cgScreen.minX, cgScreen.maxX - hud.width)
topLeft.y = clamp(topLeft.y, cgScreen.minY, cgScreen.maxY - hud.height)

return cgTopLeftToAppKitOrigin(topLeft, hud: hud)
```

`NSScreen.containing(_:)` = `screens.first { $0.frame.contains(anchor) } ?? .main`. Multi-monitor: all math stays in points; CGEvent coords (top-left global plane, allowing negative) and AppKit coords (bottom-left per-screen-flipped) are converted only at the boundary. See `docs/21_coordinate-systems.md`.

## 6. Feedback-loop avoidance & approach-freeze

We **cannot** use `panel.ignoresMouseEvents = true` (the HUD has Start/Stop, Clear, Export, ×, gear, compact-toggle buttons). Three guard rails instead:

1. **Cursor approaching the HUD's current frame → freeze.** At the top of every apply step, read `NSEvent.mouseLocation`. If the cursor is inside `panel.frame` inflated by `approachPad` (12 pt), drop the update entirely. **Crucial:** the check is against the HUD's **current** frame, not the candidate frame. With any non-zero offset, the candidate frame by construction never contains the cursor (HUD is `dx,dy` away from the anchor) — so a candidate-frame check would never fire and the HUD would flee the cursor forever, leaving the user unable to click it. The current-frame + pad check gives the cursor a landing zone: as soon as it gets within 12 pt of the HUD's edge, the HUD freezes and waits to be clicked.
2. **User drag suspends follow for 5 s.** `FloatingPanel.mouseDown` calls `controller.userDidDrag()` before `performDrag(with:)`. While suspended, anchors are tracked but not applied. Resume only after the anchor has moved ≥ 4 pt — so the HUD doesn't yank back to a stationary anchor when the timer expires.
3. **Dead-zone:** only reapply when delta from last applied origin ≥ 0.5 pt (also serves as the main-queue hop gate from §3).

The approach-freeze applies uniformly in `followPointer` and `followCaret`, since both modes need to let the user reach the HUD with the mouse (the gear/compact-toggle/× buttons must remain clickable in either mode).

In `pinned` mode the controller is a no-op; `FloatingPanel.panelDidMove` continues to write `hud.frame.originX/Y` as today.

## 7. Privacy / secure input

`CaretFollower` checks `IsSecureEventInputEnabled()` **and** focused element subrole `AXSecureTextField` at the top of every refresh. If either is true: freeze in place, do not query AX, do not log. Matches the existing service-layer drop in `EventTapService.handle(type:event:)` for secure keyDowns. Apple's TN2150 doesn't speak to HUDs specifically but its privacy intent is clear; conservative read = suppress.

## 8. Settings UI

Replace the no-op `Settings { EmptyView() }` in `ManifestApp.swift` with a real form. **Cmd+, does NOT work under `.accessory` activation policy** — `NSApp.setActivationPolicy(.accessory)` strips the main menu entirely, so SwiftUI's `Settings` scene has no menu item to bind the shortcut to. The gear `Button` in the expanded header (`ContentView.settingsButton`) is the actual entry point. It calls `NSApp.activate(ignoringOtherApps: true)` (the Settings window otherwise wouldn't take focus under `.accessory`) followed by SwiftUI's `@Environment(\.openSettings)` action.

```swift
// Views/PreferencesView.swift
Form {
    Section("Placement") {
        Picker("Mode", selection: $vm.placementMode) {
            Text("Pinned").tag(PanelPlacement.pinned)
            Text("Follow pointer").tag(PanelPlacement.followPointer)
            Text("Follow caret").tag(PanelPlacement.followCaret)
        }.pickerStyle(.segmented)

        if vm.placementMode != .pinned {
            Stepper("Horizontal offset: \(Int(vm.placementOffset.dx)) pt",
                    value: $vm.placementOffset.dx, in: -200...200, step: 4)
            Stepper("Vertical offset: \(Int(vm.placementOffset.dy)) pt",
                    value: $vm.placementOffset.dy, in: -200...200, step: 4)
            Toggle("Flip near screen edges", isOn: $vm.placementOffset.flipNearEdges)
        }
        if vm.placementMode == .followCaret {
            Text("Some apps (Electron, Terminal, web inputs) don't expose caret bounds — the HUD will freeze in place when used in those apps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
.frame(width: 360).padding()
```

Live-edit happens for free: `@Bindable` VM properties trigger `didSet` → controller observes → `applyTargetOrigin` runs.

Rejected alternatives: right-click context menu (hidden discoverability, conflicts with the `performDrag` `mouseDown` override); inline header controls (crowds an already-busy row, forces visibility tradeoff with compact mode).

## 9. Persistence (UserDefaults)

| Key | Type | Default |
|---|---|---|
| `hud.placement.mode` | String (rawValue) | `"pinned"` |
| `hud.placement.dx` | Double | `24` |
| `hud.placement.dy` | Double | `24` |
| `hud.placement.flipNearEdges` | Bool | `true` |
| `hud.frame.originX/Y` | Double | *(unchanged; pinned-mode origin)* |

In follow modes, `hud.frame.origin*` is NOT updated — the offset is the persisted thing. Switching back to pinned restores the last pinned origin. No migration needed (single-user dev project per `PROJECT_STATE.md`).

## 10. Files

**Create:**
- `01_Project/Manifest/Models/PanelPlacement.swift` — enum + struct.
- `01_Project/Manifest/Services/PanelPlacementController.swift` — orchestrator.
- `01_Project/Manifest/Services/PointerFollower.swift` — `CADisplayLink` + `NSEvent.mouseLocation`.
- `01_Project/Manifest/Services/CaretFollower.swift` — `AXObserver` + bounds-for-range.
- `01_Project/Manifest/Services/PlacementMath.swift` — pure math.
- `01_Project/Manifest/Views/PreferencesView.swift` — Settings form.
- `01_Project/ManifestTests/PlacementMathTests.swift` — unit tests.

**Modify:**
- `ManifestApp.swift` — `Settings { PreferencesView(vm: …) }`; instantiate the controller in `applicationDidFinishLaunching` after the panel is created; call `start()`.
- `FloatingPanel.swift` — `weak var placementController`; `mouseDown` calls `placementController?.userDidDrag()`; `panelDidMove` guards origin-write on `placementController?.mode == .pinned`.
- `ViewModels/EventStreamViewModel.swift` — add `placementMode`, `placementOffset` `@Observable` properties + `didSet` persistence; expose `frontmostAppChanged` hook into `FrontmostAppMonitor` for the caret rebind.
- `01_Project/project.yml` — regenerate via `cd 01_Project && xcodegen` after adding files.

## 11. Tests

**Unit (PlacementMathTests):** `applyOffset` for combinations of anchor/dx/dy/hud size; `flipQuadrant` symmetry; `clampToScreen` for points outside both edges and for negative-x screens (left-of-primary monitor); CG↔AppKit round-trip; edge cases (anchor on screen boundary, HUD wider than screen — must not loop).

**Manual:**
- TextEdit (gold path — full AX support).
- Chrome address bar + a `<input>` (caret bounds mostly only work with VoiceOver — verify field-rect fallback engages and statusMessage says "docking to text field").
- VS Code / Cursor (Electron — verify field-rect fallback docks HUD under the editor pane, not freeze).
- Terminal.app and iTerm (no caret AND likely no useful field rect — verify final freeze tier and "HUD held in place" statusMessage).
- App-switch between tiers (e.g. TextEdit → VS Code → Terminal): verify each switch surfaces the right one-shot statusMessage and doesn't spam.
- Dual monitor, primary + left-of-primary (negative CG coords).
- Drag-during-follow, 5 s resume, anchor-must-move-4pt gate.
- Cursor approaches HUD in pointer mode — HUD freezes within 12 pt of its current frame, letting the user click the gear/×/compactToggle.
- After clicking the gear, the Settings window opens and takes focus despite `.accessory` policy.
- Display sleep / wake — `CADisplayLink` pauses + resumes cleanly.
- Secure field (1Password, login window) — HUD freezes in place.

## 12. Risks & open questions

- **AX observer storms under fast typing** — coalesce at 16 ms; if still too noisy, drop to 33 ms.
- **AXObserver references go stale on target-app crash** — `FrontmostAppMonitor` rebinds on switch; 250 ms `AXUIElementSetMessagingTimeout` caps any blocked call.
- **Field-rect anchor in giant editors.** A whole VS Code editor pane can be 800×600 pt; anchoring HUD to its bottom-left puts the HUD under the pane, which is roughly right but not next-to-caret. Acceptable — user can switch to pointer or drag to tune offset. If complaints surface, revisit with caret approximation via `kAXVisibleCharacterRangeAttribute` (not all apps support it either).
- **statusMessage one-shot dedup.** Need a small `lastFallbackTier: (pid, tier)` cache in `CaretFollower` so the message fires once per app-switch, not on every observer fire.
- **`approachPad = 12 pt` is a hand-tuned value.** Too small and the user has to be precise; too large and the HUD freezes prematurely when the cursor is just moving past. Revisit if users report either failure mode.

### Resolved
- ~~Caret-missing fallback~~ → **caret → focused-field rect → freeze** (NOT pointer). See §4 fallback chain. Decided 2026-05-28.
- ~~Cmd+, under `.accessory` policy~~ → **Cmd+, doesn't work**, because `.accessory` removes the main menu entirely. The gear button in `ContentView.expandedHeader` is the actual entry point. See §8. Discovered during implementation 2026-05-28.
- ~~Original §6.1 "candidate frame contains pointer" guard~~ → **broken by construction**: with non-zero offset the candidate frame never contains the cursor, so the HUD fled forever and was unreachable. Replaced with "current frame + 12 pt approach pad" check using `NSEvent.mouseLocation`. See §6.1. Fixed 2026-05-28.

## Sources

- Apple — `kAXBoundsForRangeParameterizedAttribute`, `kAXSelectedTextChangedNotification`, `kAXFocusedUIElementChangedNotification`, `AXObserverAddNotification`, `AXUIElementSetMessagingTimeout`, `NSEvent.mouseLocation`, `NSScreen.visibleFrame`, Tech Note TN2150 (Secure Event Input).
- Apple Dev Forums #802423 — AX IPC + Swift cooperative pool starvation.
- [CursorBounds](https://github.com/Aeastr/CursorBounds) — reference impl of the focused-text-bounds fallback chain.
- [AXSwift](https://github.com/tmandry/AXSwift) — messaging-timeout and observer patterns.
- Internal: `docs/21_coordinate-systems.md`, `docs/decisions.md` (2026-05-27 DownKeyCounter adoption — AX worker pattern), `01_Project/Manifest/Services/AXElementLookup.swift` (pattern to mirror).
