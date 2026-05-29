# Decisions Log

WHY behind technical and design decisions for Manifest.

---

## Template

### [Date] - [Decision Title]
**Context:** [What situation prompted this decision?]
**Options Considered:**
1. [Option A] - [pros/cons]
2. [Option B] - [pros/cons]

**Decision:** [What we chose]
**Rationale:** [Why we chose it]
**Consequences:** [What this means going forward]

---

## Decisions

### 2026-05-27 — Floating always-on-top NSPanel (vs menu bar or regular window)

**Context:** Manifest is primarily for screencasts, demos, and "what just happened?" debugging. The window needs to stay visible across Cmd+Tab, Mission Control, and full-screen apps, but must not steal focus (otherwise its own existence would distort the input being captured).

**Options Considered:**
1. **Menu bar app with popover** — Minimal screen footprint, but invisible during use; defeats the demo purpose.
2. **Regular SwiftUI `WindowGroup`** — Easy to build, but goes behind other apps and loses Z-order across Spaces.
3. **`NSPanel` subclass with `.floating` level, `.nonactivatingPanel` style, no key/main focus** — Always visible, never steals focus, behaves like a HUD overlay.

**Decision:** Option 3.

**Rationale:** Non-activating floating panels are the standard pattern for keyboard-input visualizers (KeyCastr, Mac OS X's accessibility keyboard, etc.). The non-activating mask is critical — without it, every click on the panel would change the frontmost app, which would corrupt our own `bundleID` attribution.

**Consequences:**
- We need a thin `NSPanel` host bridged into SwiftUI via `NSViewControllerRepresentable` or a custom `NSApplicationDelegateAdaptor`.
- The window cannot host menu commands the normal way; we surface controls (pause, clear, export) inside the panel body or in a menu bar item.

---

### 2026-05-27 — Adopt DownKeyCounter's CGEventTap pipeline verbatim where it fits

**Context:** `DownKeyCounter` (same author, also a macOS utility under `~/ProgrammingProjects/1-macOS/`) already has a hardened CGEventTap pipeline: `EventTapService`, `AXElementLookup`, `FrontmostAppMonitor`, `ModifierTapDetector`, `KeyNameMapper`. It handles auto-repeat filtering, tap-disabled re-enabling, AX recursion crashes when clicking on its own UI, multi-display negative coordinates, and FIFO eviction of orphan hold entries. Manifest needs roughly the same surface.

**Options Considered:**
1. **Copy files as-is, rename namespace.** Fastest path. Risk: drift between the two projects over time.
2. **Extract a shared `KeyTap` SPM package.** Cleanest long-term, slowest now. Both projects would consume it.
3. **Re-implement from scratch in Manifest.** Wasteful; the gotchas (AX in-process recursion, auto-repeat filtering) are exactly the kind of thing that takes a week to rediscover.

**Decision:** Option 1 for v1. Revisit Option 2 once both apps have shipped at least once and the API surface stabilizes.

**Rationale:** The cost of "drift" only matters if both projects keep evolving. For now, Manifest' goals are narrower than DownKeyCounter's (no hold-time analytics, no per-app filtering UI, no bucketing). We copy what we need, drop what we don't, and only extract a package when the third consumer appears.

**Consequences:**
- Keep DownKeyCounter's file headers/comments intact when copying so the provenance is visible.
- Diverging changes happen in Manifest first; if a fix or pattern proves general, we backport to DownKeyCounter and consider extraction.

---

### 2026-05-27 — Persist locally to Application Support + export on demand (no auto-export)

**Context:** Users requested "live stream + persistent log + export, just in case." Persistent log is for resuming after a crash or app restart; export is for sharing or analysis. Auto-exporting on every event would be noisy and risk leaking sensitive input data.

**Decision:** Append-only JSONL at `~/Library/Application Support/Manifest/events-YYYY-MM-DD.jsonl`. Manual `Export…` button writes the currently-displayed session to a chosen path (CSV + JSON).

**Rationale:** JSONL is append-friendly, crash-safe, and trivially streamable. CSV/JSON export is on-demand to keep secrets out of the home folder by default.

**Consequences:**
- Need a small rotation policy (one file per UTC day; cap retained files at 30 by default).
- Document in README that the file contains keystroke-level data and should not be shared blindly.

---

### 2026-05-27 — Both local and UTC timestamps per row

**Context:** User explicitly asked for both. Local is for human reading; UTC is the canonical machine timestamp.

**Decision:** Store one `Date` (UTC implicit) per event, render as `HH:mm:ss.SSS` local + `HH:mm:ss.SSSZ` UTC in the UI; export both columns in CSV/JSON.

**Rationale:** A single `Date` is the source of truth. Local rendering is a presentation concern, not a storage concern.

**Consequences:** None significant — `DateFormatter` configured with `en_US_POSIX` locale to avoid locale-specific surprises.

---

### 2026-05-27 — Track frontmost app via KVO, not `didActivateApplicationNotification`

**Context:** All captured events were being stamped with whatever app happened to be frontmost when the last `NSWorkspace.didActivateApplicationNotification` arrived. Observed in the wild: after switching from Manifest into Stills From Video, every subsequent click/scroll/key — even while clearly in TextEdit or Warp — was tagged "Stills From Video". The notification was firing intermittently and then silently dropping further activations.

**Options Considered:**
1. **Stay on `didActivateApplicationNotification`, add a periodic poll as a tiebreaker.** Cheap, but masks the bug rather than fixing it; polling cadence is a knob with no good answer.
2. **Belt-and-braces: KVO + notification.** Two writers, risk of duplicate `appSwitch` rows; extra code for marginal safety.
3. **KVO on `NSWorkspace.shared.frontmostApplication`.** Single source of truth, fires on every frontmost change including the cases the notification drops.

**Decision:** Option 3.

**Rationale:** `NSWorkspace.didActivateApplicationNotification` has documented and field-observed reliability issues in modern macOS (Sonoma/Sequoia), particularly for `.accessory`-policy observers — which is exactly our profile. KVO on `frontmostApplication` is the AppKit-native replacement and is what other long-running frontmost-aware utilities (clipboard managers, window managers) have moved to.

**Consequences:**
- `FrontmostAppMonitor.observation: NSKeyValueObservation?` replaces the old `observer: NSObjectProtocol?`. Lifecycle: created in `start()`, invalidated in `stop()`.
- KVO callbacks can fire off-main, so the handler hops to `MainActor` via `Task { @MainActor in … }` before writing `currentBundleID`. The pointer-sized `currentBundleID` read from the C tap callback stays lock-free as before.
- `onSwitch(from:to:)` semantics unchanged — `EventTapService.emitAppSwitch` and the live HUD continue to receive app-switch rows.
- If KVO itself ever goes stale (e.g. during certain fullscreen-app transitions), the fallback is a low-rate `frontmostApplication` poll — not yet needed.

---

### 2026-05-27 — Quit affordance: in-panel × only (no Cmd+Q, no status bar item)

**Context:** After going borderless we lost the system traffic lights. Three quit paths were considered: (a) SwiftUI `.keyboardShortcut("q", .command)` on the × button, (b) an `NSStatusItem` with a Quit menu, (c) just the × button.

(a) silently doesn't work: with `.accessory` activation policy + `.nonactivatingPanel`, Manifest is never the OS-active app, so Cmd+Q is routed to whichever real app *is* active. SwiftUI's `.keyboardShortcut` hooks the app menu, which only fires for the active app.

(b) was tried and implemented. The status item was confirmed created (visible in System Settings → Menu Bar with Manifest toggled on), but never appeared in the menu bar in practice — eaten by the user's menu bar manager (Barbee) despite being toggled on, with no obvious reason (no overflow; visible empty space in the menu bar). The combination of "you have to dig in Barbee config to find a status item that should just appear" was worse UX than no status item.

**Decision:** Keep the × button in the expanded header as the single quit path. Drop the `.keyboardShortcut` (was lying about what worked). Drop the `StatusBarController`.

**Rationale:** The × button is discoverable from the panel, works reliably, and the failure modes of the alternatives (silent shortcut, invisible menu bar icon) are worse than the trade-off of having to expand from compact to quit.

**Consequences:**
- The compact mode must always be expandable via the chevron — collapsing to compact is the "hide" gesture; expanding gives back the × for quit.
- `applicationShouldTerminateAfterLastWindowClosed = false` is still required (Export NSSavePanel dismissal would otherwise terminate the app — see prior decision).
- If a future user genuinely needs Cmd+Q, the workable path is a Carbon `RegisterEventHotKey` for a *non-conflicting* combo (e.g. ⌘⇧Q), not Cmd+Q. Documented as "later, if asked."

---

### 2026-05-27 — Persist `isCompact` via UserDefaults

**Context:** Compact/expanded was reset to expanded on every launch. Mildly annoying for screencast use — the user picks compact, quits, relaunches, and has to collapse again.

**Decision:** `EventStreamViewModel.isCompact` reads its initial value from `UserDefaults.standard.bool(forKey: "hud.isCompact")` in `init`, and writes back on every change via `didSet`. No new infrastructure; no `@AppStorage` (would have required moving ownership of the toggle out of the VM).

**Rationale:** Smallest possible change. `didSet` plays cleanly with `@Observable` (the macro doesn't interfere with property observers). The key is scoped (`hud.<name>`) so future panel-position / window-state keys can share the same namespace.

**Consequences:**
- First launch defaults to expanded (`UserDefaults.bool(forKey:)` returns `false` for missing keys), matching prior behavior.
- Same pattern will be reused for panel-position persistence and any other future HUD preferences.

---

### 2026-05-27 — AX enrichment of mouse rows via off-main worker

**Context:** Mouse rows show "Left Click — Warp @ 581,246" — useful, but doesn't say *what* in Warp got clicked. AX (`AXUIElementCopyElementAtPosition`) can resolve the element's role and title ("Button 'Quit'", "TextArea '…'"), but it's synchronous IPC with a default ~6 s timeout and a known in-process recursion crash. DownKeyCounter/Tachograph already has a hardened worker for this — `Services/AXElementLookup.swift` — with empirically-tuned numbers from prior incidents.

**Options Considered:**
1. **Inline AX in the tap callback.** Simplest call site, but blocks the main run loop on every click. A single unresponsive target app stalls capture for seconds. Rejected.
2. **Async/await Task per lookup, no queue.** Cleaner Swift, but unbounded concurrency — a burst of clicks against a slow target produces a pile-up of in-flight AX calls each holding a 250 ms timeout. Backpressure becomes implicit.
3. **Port DKC's serial-queue worker verbatim.** Soft-capped FIFO, deadline-drop, 250 ms AX timeout cap. Battle-tested numbers, known recursion guard.

**Decision:** Option 3, with two adaptations for Manifest' model:
- AX enqueue lives in `EventStreamViewModel`, not `EventTapService`. Manifest already runs `hitTestOwnPanel` in the VM for click attribution; reusing it as the recursion guard avoids duplication and keeps the tap service single-purpose. Latency cost (one Task hop from tap callback through `AsyncStream` into VM) is invisible vs. AX's own IPC.
- Recursion guard is **geometric** (`hitTestOwnPanel(point)`), not bundleID-based. DKC checks `frontmost == ownBundleID`, but Manifest' `.nonactivatingPanel` means frontmost stays the *other* app even while the user clicks ours — bundleID guard would miss the crash case entirely. Geometric hit-test is the precise predicate.

**Rationale:** Avoids re-discovering the failure modes the DKC author already paid for (the long docstring on DKC's `EventTapService.shouldEnqueueAX` documents the in-process AX → SwiftUI → MainActor isolation SIGTRAP). Existing tests transfer almost verbatim.

**Consequences:**
- New `Services/AXElementLookup.swift` with the worker. New `axRole`/`axTitle` vars on `InputEvent`. New `applyAX(id:role:title:)` patcher on the VM. New AX-aware segment in `EventRowView`. Two new CSV columns in `Exporter`.
- AX is **live-display only, not persisted to JSONL.** The on-disk log stays "what the tap saw at capture time"; AX patches the in-memory `events` array only. Exports read the live array so they include AX. Documented.
- Skipping AX for own-panel clicks loses the ability to AX-introspect our own HUD, which is fine — we're not the interesting target.
- 10 unit tests cover the worker's fallback chain, deadline drop, and queue cap. AX-against-real-targets is observed-only (would require a UI test driver to make deterministic).

---

### 2026-05-27 — Persist panel top-left origin via UserDefaults

**Context:** Sibling to the `isCompact` persistence change. The panel re-centered itself on every launch — annoying when the user has parked it in a screen corner for screencasts. Same `hud.*` namespace as before.

**Options Considered:**
1. **Save full `frame` as a string ("{{x, y}, {w, h}}").** Matches `NSWindow.saveFrame(usingName:)` style. But our size is SwiftUI-driven (compact ↔ expanded, fixed width 520) — persisting size would conflict with the layout code that recomputes it.
2. **`NSWindow.setFrameAutosaveName`.** AppKit's built-in mechanism. Rejected because (a) it persists size too, same problem as (1), and (b) the autosave plist key uses a window name we'd have to also wire into the `NSPanel` init, making the data harder to inspect/clear via UserDefaults.
3. **Save origin only as two `Double`s under `hud.frame.originX` / `hud.frame.originY`.** Smallest surface. Plays nicely with the SwiftUI-driven size.

**Decision:** Option 3. Restore in `FloatingPanel.init` if both keys exist *and* the saved origin lands on a currently-connected screen (`NSScreen.screens.visibleFrame.intersects(candidate)`); otherwise `center()`. Save on every `NSWindow.didMoveNotification`.

**Rationale:** Drags are infrequent (one notification per move-end, not per pixel), so no debounce needed. The on-screen validation is the only non-obvious bit — without it, disconnecting a monitor between sessions would put the panel into never-never-land on relaunch.

**Consequences:**
- First launch (no saved keys) centers as before — backward-compatible.
- Monitor disconnect → relaunch falls back to centering, not stranding the user.
- `hud.frame.originX/Y` joins `hud.isCompact` in the `hud.*` namespace; defaults inspectable via `defaults read com.lucesumbrarum.Manifest`.
- Compact/expanded toggle preserves the user's anchor (already true — only height changes), so the saved origin remains valid across mode switches.

---

### 2026-05-28 — Expanded view stays fixed at 520×360 (no resize)

**Context:** The borderless rewrite on 2026-05-27 dropped `.resizable` from the panel's styleMask, leaving the expanded view at a fixed 520×360. Open question: should resize come back?

**Options Considered:**
1. **Re-add `.resizable` to styleMask.** Smallest API surface, but the styleMask gotcha that prompted the borderless rewrite (transparent titlebar gap on re-expand) lives in this same area — risk of regression. Also re-introduces an OS-drawn resize affordance that doesn't match our SwiftUI chrome.
2. **SwiftUI gesture-based resize (drag handle).** Keeps styleMask alone, but breaks the "compact width = expanded width" invariant that makes the compact-toggle animation feel clean — width changes would have to track mode, and collapsing to compact would have to either snap back to 520 or change the compact width too.
3. **Two/three discrete heights (short / tall) toggled from header.** Predictable, screencast-friendly, doesn't touch styleMask. More work than (1), less flexible than (2).
4. **Keep fixed.** No new code, no new failure modes.

**Decision:** Option 4.

**Rationale:** Three orthogonal size controls (compact toggle + width drag + height drag) is too much UI for a HUD whose job is staying out of the way. The compact ↔ expanded toggle already covers the "smaller footprint" use case. 360 px shows ~12-15 rows; with the 200-event in-memory cap, scrolling fills the "see more history" gap. AX titles already truncate cleanly in `EventRowView`. If pain shows up in practice (small laptop vs 4K external monitor), the cheapest follow-up is Option 3 (discrete heights), not free-form resize — but logging this decision means it stays off the active list until that pain is actually felt.

**Consequences:**
- `FloatingPanel` keeps its fixed 520×360 `contentRect`.
- "Resizable expanded view" comes off the Next Actions list in `PROJECT_STATE.md`.
- If we ever need this, the path forward is Option 3 (header-driven discrete heights), not Option 1 or 2.

---

### 2026-05-27 — Drop own-panel mouse events entirely (don't re-attribute, don't log)

**Context:** Initial AX wiring kept the pre-existing behavior of re-attributing own-panel mouse clicks to Manifest in the bundleID — they still appeared in the live list as `Manifest @ x,y`. Testing showed this is just noise: own-panel clicks are HUD-control interactions (Start/Stop, Clear, Export, the chevron, the ×, panel drags), not user input worth logging.

**Decision:** `EventStreamViewModel.handle(_:)` early-returns when an event is `.mouse` and its point hits `hitTestOwnPanel`. Not persisted, not inserted into the live list, no AX enqueue.

**Rationale:** Manifest is a tool for capturing what the user does in *other* apps. Logging the user's own interactions with the HUD itself is meta-noise that drowns out the signal during screencasts.

**Consequences:**
- The persisted JSONL becomes "input you sent to other apps" — cleaner record for export/replay/analysis.
- The previous bundleID-re-attribution code is dead and removed.
- Scroll events on the panel are not yet filtered (scrolls don't carry a click point in the current model). If panel scroll-on-panel noise becomes annoying, add coord capture to scroll events and the existing filter applies for free.

### 2026-05-28 — Repair click-attribution race via AX element PID

**Context:** The tap callback stamps `bundleID` from `FrontmostAppMonitor.currentBundleID` at click time. When the frontmost app changes within ~50 ms of a click (Cmd+Tab still in flight, dock click + immediate target click, etc.), the row was stamped with the *outgoing* app — not what was actually under the cursor. The KVO frontmost fix (2026-05-27) closed the seconds-long drift but couldn't close this sub-frame window: the click and the activation notification race inside the run loop.

**Options Considered:**
1. **Buffer the row** until KVO settles (delay every mouse-row insert ~50 ms) — adds visible latency to every click, not just racy ones.
2. **Resolve `bundleID` from the AX element's owning PID** via `AXUIElementGetPid` + `NSRunningApplication(processIdentifier:)`, re-stamp the row when the PID disagrees with the frontmost snapshot — piggy-backs on the AX enrichment we already do, costs nothing in the common case.
3. **Live with it** and document the race — cheapest, but corrupts the very thing the tool exists to show.

**Decision:** Option 2. `AXElementLookup.onResult` gains a `pid_t` payload; `EventStreamViewModel.applyAX` resolves PID → bundleID and overwrites `bundleID`/`appName` on the in-memory row when they disagree.

**Rationale:** The AX element under the click is by definition the right answer — it's the actual UI the click hit. The frontmost snapshot is a *proxy* for that answer; when the proxy disagrees, AX wins. The fix reuses the worker we already pay for and doesn't move any latency into the click → row path.

**Consequences:**
- `InputEvent.bundleID` and `appName` move from `let` to `var` (matching `axRole`/`axTitle`); InputEvent doc comment updated to reflect that mouse rows are no longer fully immutable.
- The persisted JSONL is **not** patched — same policy as `axRole`/`axTitle`: AX enrichment is a live-display concern, the on-disk log stays a faithful record of what the tap stamped. Exports replayed via `preload` retain the original (possibly racy) bundleID. Acceptable because the JSONL is a debug/forensic record, not the user-facing surface; if this hurts later, the fix is to defer mouse-row `store.append` until AX resolves (or the deadline expires).
- If the AX element's PID has no live `NSRunningApplication` (process died between click and AX response — rare), the original stamp is kept as-is.
- AX worker now drops requests whose `AXUIElementGetPid` returns failure or PID 0, same drop-policy as `nil` roles — those rows just stay un-enriched (and un-re-stamped).

### 2026-05-28 — Drive window drag with `performDrag(with:)`, not `isMovableByWindowBackground`

**Context:** A persistent "sometimes you cannot drag the compact panel up" bug. The 32 pt tall strip would refuse upward motion past some point and only unstick after an expand→collapse cycle. Down/left/right always worked.

**Investigation:** Added NSLog instrumentation for `mouseDown`, `mouseDragged`, `constrainFrameRect`, `setFrame`, and `didMove`. Reproductions showed `mouseDown` arriving at the panel, a handful of `mouseDragged` events with cursor positions tracking, the window moving for the first few hundred milliseconds, then **all event delivery to the window stopping mid-drag**. No `constrainFrameRect` PASS/CLAMP, no `didMove`. The cursor's window-local coordinate exited the panel's 32 pt height almost immediately, and AppKit's `isMovableByWindowBackground` heuristic — which only anchors the drag once the cursor has moved a few points while still inside the panel bounds — was silently giving up.

**Options Considered:**
1. **Override `constrainFrameRect`** to permit the panel to move anywhere intersecting a screen — what we initially tried. Didn't help, because the events never reached the constraint stage; the drag itself was being aborted.
2. **Override `mouseDown` and call `performDrag(with:)`** — Apple's documented escape hatch. Forces an explicit drag session that captures the mouse globally, bypassing the height-sensitive heuristic.
3. **Make the panel taller** (no compact mode) — would mask the bug but defeats the whole point of the compact HUD.

**Decision:** Option 2. `isMovableByWindowBackground = false`; `mouseDown` calls `performDrag(with:)`. The bogus `constrainFrameRect` override from option 1 was removed (was never load-bearing).

**Rationale:** `mouseDown` reaches the panel only when no SwiftUI control (button, menu) consumes the event first — so "click controls, drag background" is preserved for free without enumerating drag-handle regions. `performDrag` captures the mouse globally, so the drag survives the cursor leaving the panel's bounds. The narrow compact strip stops being a special case.

**Consequences:**
- Drag works reliably in both compact and expanded modes.
- The expand→collapse workaround is unnecessary.
- If any SwiftUI element ever bubbles its `mouseDown` up to the responder chain (e.g. a custom view that doesn't claim events), it'll inadvertently start a drag. Default SwiftUI controls already consume `mouseDown`, so today's UI is fine, but a custom hit-test surface in the future would need a guard.

---

### 2026-05-28 — Sync panel size to persisted `isCompact` via `onAppear`

**Context:** `resizePanel(_:)` is wired to SwiftUI's `onChange(of: vm.isCompact)`. At launch with `hud.isCompact = true` already persisted, the value doesn't *change* — so `onChange` never fires, and the window stays at its 520×360 init `contentRect` even though the visible content is the 32 pt compact strip. The lower 328 pt is a ghost hit-area (transparent material + clip shape extends through it because SwiftUI fills the host) that swallows drags landing there.

**Decision:** Add `.onAppear { resizePanel(toCompact: vm.isCompact) }` next to the existing `onChange`. Runs once after the panel is in `NSApp.windows`, syncing window size to VM state.

**Rationale:** Cleanest fix without restructuring FloatingPanel's init to know about the VM. The view already owns the resize logic; `onAppear` reuses it.

**Consequences:**
- One extra `setFrame` at launch (a few frames after the panel appears). Brief visual flicker is acceptable for a HUD that opens once and stays open.
- `resizePanel` now also guards against the post-resize frame landing entirely off-screen — necessary because a saved expanded position with its top above the menu bar would, when collapsed via preserve-top, land the much shorter strip in the void. Falls back to centering on the main visibleFrame.

---

### 2026-05-28 — Three HUD placement modes with live-editable offset (pinned / followPointer / followCaret)

**Context:** The HUD had only one mode: drag-to-place, with origin persisted across launches. User asked whether the distance from the cursor or text caret could be made user-definable. Once the answer was "the HUD doesn't follow anything today," the question became *should it*, and if so, how. Full spec at `docs/specs/placement.md`.

**Options Considered:**
1. **Add a `dx, dy` offset and a single follow-target setting** (pointer OR caret, with a "follow" toggle and offset). Smaller surface, but the two follow targets answer fundamentally different questions ("track where I'm pointing" vs "track where I'm typing") and the user might want neither today and pointer-follow tomorrow. A two-state setting (off / on) can't express that without a separate target dropdown.
2. **A `PanelPlacement` enum with three modes — `pinned` / `followPointer` / `followCaret` — plus an offset that only applies to follow modes.** More cases, but each one is a distinct mental model. `pinned` preserves today's behavior exactly. The follow modes share the offset model (signed dx/dy + edge-flip toggle), so the math and Settings UI scale to all three without code duplication.
3. **Anchor-corner enum instead of signed dx/dy** (e.g. `topLeft`/`topRight`/`bottomLeft`/`bottomRight` + a single positive offset). Cleaner conceptually, but doubles the model size (corner picker + offset) for UI that's no easier to operate than two `Stepper`s — and edge-flip logic becomes "swap enum case" instead of `dx = -dx`, which is more code, not less.

**Decision:** Option 2, with signed dx/dy. Persistence under the existing `hud.*` namespace: `hud.placement.mode` (raw string), `hud.placement.dx` / `dy` (Double), `hud.placement.flipNearEdges` (Bool). Defaults: `pinned`, `(24, 24)`, `flipNearEdges = true`.

**Rationale:** The three-mode enum makes today's pinned behavior the explicit default and adds two opt-in modes without changing semantics for existing users. Signed dx/dy collapses what would otherwise be a corner-picker + magnitude into two `Stepper`s. The 24 pt default clears a standard ~16 pt cursor hot-spot without floating off into the distance.

Architecturally: a `PanelPlacementController` (service) owns the followers (`PointerFollower` using `CADisplayLink` + `NSEvent.mouseLocation`; `CaretFollower` using `AXObserver` + `kAXBoundsForRangeParameterizedAttribute`), applies the resulting origin to the panel, and handles drag-suspension + approach-freeze. `EventStreamViewModel` owns the mode + offset state via `@Observable` properties with `didSet` UserDefaults persistence. Settings UI lives in a real SwiftUI `Settings { ... }` scene with a segmented `Picker` and two `Stepper`s. Live edit happens via Observation — no save button. Mirrors the existing "services own work, VM owns state, view is dumb" pattern.

**Consequences:**
- 7 new files: `Models/PanelPlacement.swift`, `Services/PlacementMath.swift` (pure CG↔AppKit + flip/clamp), `Services/PointerFollower.swift`, `Services/CaretFollower.swift`, `Services/PanelPlacementController.swift`, `Views/PreferencesView.swift`, `ManifestTests/PlacementMathTests.swift` (12 unit tests).
- 3 modified: `ManifestApp.swift` (real `Settings` scene + controller wiring), `FloatingPanel.swift` (calls `userDidDrag()` + gates `panelDidMove` persistence on pinned mode), `EventStreamViewModel.swift` (new properties + `monitor` exposed as internal so the controller can piggy-back its `onSwitch` for caret-observer rebinding).
- `hud.frame.originX/Y` semantics unchanged: it remains the pinned-mode origin. In follow modes the controller suppresses `panelDidMove`-driven writes so the pinned anchor is preserved across mode toggles.
- Three knock-on decisions follow this one (caret fallback, Cmd+, replacement, approach-freeze); they're logged separately.

---

### 2026-05-28 — Caret-missing fallback chain: caret → focused-field rect → freeze (NOT pointer)

**Context:** Many apps don't expose per-character caret bounds via AX. The research surfaced a known-flaky list: all Electron-based editors (VS Code, Cursor, Slack, Discord, Notion), Terminal/iTerm/Ghostty, web text inputs in Chrome/Safari/Firefox (unless VoiceOver is on), JetBrains IDEs, secure text fields. `followCaret` had to do *something* in these apps; the question was what.

**Options Considered:**
1. **Full chain: caret → focused-field rect → pointer.** The CursorBounds reference implementation's approach. Always shows the HUD *somewhere* relevant.
2. **Caret-only, freeze on miss.** Honest about the failure. HUD just stops moving.
3. **Caret → focused-field rect → freeze.** Hybrid. Uses the focused element's frame (`kAXPosition` + `kAXSize`) when per-character bounds are unavailable but the element itself is reachable — common in Electron — then freezes only as last resort.

**Decision:** Option 3.

**Rationale:** The user explicitly picked `followCaret` because they want the HUD near where text is going. The pointer is usually parked somewhere unrelated while typing — silently teleporting the HUD to it would violate the mental model the user signed up for. The focused-field rect preserves that mental model at coarser resolution: in VS Code the editor pane's frame is exposed via AX even though per-character bounds aren't, so docking under the pane is still "near typing."

Freezing only on total failure (no caret AND no focused-element frame) is honest about the case where AX can give us nothing — much rarer than caret-bounds failure. Both fallback tiers surface in `vm.statusMessage` once per app-switch ("Caret bounds unavailable — docking to text field." / "No text position info — HUD held in place.") so the user can see which tier they're on without staring at the HUD trying to guess.

**Consequences:**
- `CaretFollower` has a three-state `Tier` enum (`caret` / `fieldRect` / `frozen`) surfaced through `onResult`. The controller writes the tier-specific status message on `(pid, tier)` transitions.
- In `frozen` tier, the HUD holds at its last successful anchor (or `.zero` if nothing ever resolved). This is acceptable on first launch in a never-resolving app: the HUD just stays where the user dragged it last.
- One open polish item: dedup logic for the status message is naive today (fires per observer event, not per pid/tier transition). Tracked in `PROJECT_STATE.md` Next Actions.
- Open question parked for later: huge editor panes (VS Code 800×600 pt) anchor the HUD at the pane's bottom-left, which is "roughly right" but not next-to-caret. Revisit with `kAXVisibleCharacterRangeAttribute` if users complain.

---

### 2026-05-28 — Settings entry is a gear button, not Cmd+,

**Context:** Shipped the `followCaret` mode behind a real SwiftUI `Settings { PreferencesView(...) }` scene. Spec §12 had flagged "`Cmd+,` under `.accessory` policy" as an open question. The implementation answered it: **Cmd+, doesn't work at all**. `NSApp.setActivationPolicy(.accessory)` strips the main menu entirely — there is no menu item for SwiftUI to bind the shortcut to. The user can press `Cmd+,` all day and nothing happens.

**Options Considered:**
1. **Switch the activation policy to `.regular`** so the app has a Dock icon and a main menu. Reverses a 2026-05-27 decision that was load-bearing for the HUD pattern (no Dock clutter; doesn't show up in Cmd+Tab; works during screencasts without making Manifest itself the focus).
2. **Temporarily promote `.accessory` → `.regular` while Settings is open, demote back when it closes.** Doable, but introduces window-lifecycle complexity and momentary Dock-icon flicker. Solves a problem the user didn't ask us to create.
3. **Carbon `RegisterEventHotKey` for `Cmd+,`** globally. Works regardless of activation policy, but registers a system-wide hotkey that conflicts with every other app's Preferences shortcut while Manifest is running. Hostile.
4. **A gear `Button` in the expanded header** that explicitly opens the Settings scene via `NSApp.activate(ignoringOtherApps: true)` + SwiftUI's `@Environment(\.openSettings)`. No global state, no menu, no hotkey conflict.

**Decision:** Option 4. Drop Cmd+, expectations entirely.

**Rationale:** The HUD already has discoverable chrome — Start/Stop, Clear, Export, ×, compact-toggle — and adding a gear glyph next to them costs ~16 pt of header width while making Settings reachable from the same surface the user already operates. `NSApp.activate(ignoringOtherApps: true)` is required because under `.accessory` the Settings window otherwise opens behind the active app and doesn't take focus. `@Environment(\.openSettings)` is the macOS-14+ public API for opening the SwiftUI `Settings` scene; we target 15, so no fallback needed.

**Consequences:**
- `ContentView` gains `@Environment(\.openSettings)` and a `settingsButton` between the Export menu and `compactToggle`.
- Settings is reachable only from the expanded header — compact mode hides it. Matches the existing pattern (× is also expanded-only), so the discovery path is consistent: "compact is the hide gesture; expand to reach controls."
- The SwiftUI `Settings { ... }` scene is still declared in `ManifestApp.body`; it's just opened programmatically rather than by menu.
- If a future user does want a keyboard shortcut, the path is the same as for Cmd+Q on 2026-05-27: a non-conflicting Carbon hotkey for something like ⌘⇧, — documented as "later, if asked."

---

### 2026-05-28 — Approach-freeze on the *current* HUD frame, not the candidate frame

**Context:** Spec §6.1 (the original anti-feedback rule) said: "if the candidate frame contains the cursor, drop the update." It was meant to prevent the chase-loop when the cursor hovers near the HUD. Implementation shipped that rule. First user test in `followPointer` exposed it as broken: the HUD fled the cursor forever and could not be clicked.

The math: with offset `(dx, dy) = (24, 24)`, the HUD's candidate frame top-left is `cursor + (24, 24)`. The candidate rect spans `[cursor.x+24, cursor.x+24+520]` horizontally. The cursor is at `cursor.x`. For the cursor to be inside that rect we'd need `cursor.x >= cursor.x + 24`, which is never true. So the rule never fired and there was no anti-feedback — the HUD repositioned every tick to be 24 pt away from wherever the cursor just moved to.

**Options Considered:**
1. **Keep the candidate-frame rule but flip its sign** ("drop if candidate frame does NOT contain cursor"). Stops the HUD entirely whenever the cursor isn't on top of it — i.e. all the time. Wrong direction.
2. **Add a dead-zone in cursor space** (only reposition when the cursor moves > N pt). Helps with jitter but doesn't fix reachability: the HUD still flees, just in larger steps.
3. **Approach-freeze on the *current* HUD frame** — at every apply step, read `NSEvent.mouseLocation`, check if it lies within the panel's current frame inflated by `approachPad` (12 pt). If yes, drop the update. Gives the cursor a 12 pt landing zone where the HUD freezes and waits.
4. **`panel.ignoresMouseEvents = true`** so the HUD is click-through entirely. Loses the gear/×/compact-toggle buttons.

**Decision:** Option 3, with `approachPad = 12 pt`. Applied uniformly to `followPointer` and `followCaret` so both modes preserve clickability of the HUD chrome.

**Rationale:** The candidate frame is the wrong rect to test — it's by construction always offset from the anchor. The current frame is where the HUD actually is on screen *right now*; if the cursor is approaching that rect, the user is reaching to click it, and "stop moving" is the only useful response. 12 pt is large enough to be reachable without precision aiming, small enough that ordinary cursor flybys past the HUD don't freeze it for long.

Uniform application across modes matters because in `followCaret` the user might also want to click the gear button — caret-driven repositioning shouldn't dodge the cursor any more than pointer-driven repositioning should.

**Consequences:**
- `PanelPlacementController.applyTopLeft` calls `isCursorApproachingHUD()` before any frame write. The helper reads `NSEvent.mouseLocation` (cheap, no IPC), converts to CG-space, and tests containment against `panel.frame` inflated by `approachPad`.
- `approachPad = 12 pt` is a hand-tuned magic number tracked in `PROJECT_STATE.md` Next Actions for revision if usage shows it too small or too large.
- The old `proposedCG.contains(cgPoint)` guard rail was removed from `handlePointerTick` — it never fired, so deleting it is a no-op behavior-wise and removes a misleading line of code.
- Spec `docs/specs/placement.md` §6.1 was rewritten post-implementation to reflect the working rule, and the broken original is logged under §12 "Resolved" so the failure mode is captured for future reference.

### 2026-05-28 — `statusMessage` tier-transition dedup lives in `CaretFollower`, not the controller

**Context:** Spec §12 anticipated that follow-caret would need a `(pid, tier)` cache to fire the "Caret bounds unavailable…" / "HUD held in place" messages once per app-switch or tier change — not on every `AXObserver` event, which can fire per glyph during fast typing. The first implementation put that cache in `PanelPlacementController` (`lastCaretPID` + `lastCaretTier` ivars + an inline check in `handleCaretResult`). It worked for the spam-prevention case but had four bugs in adjacent behavior:

- **(A)** `applyForCurrentMode` only cleared `statusMessage` on `.pinned`; switching to `.followPointer` left a stale "Caret bounds unavailable…" message visible.
- **(B)** Re-entering `.followCaret` while still in the same (pid, tier) didn't re-surface the warning because the controller's cache was unchanged.
- **(C)** The `.followCaret` branch called `caret.frontmostAppChanged(pid:)` to "force an immediate read" — but that method early-outs when the PID matches `currentPID`, so the read was never scheduled and the message could be arbitrarily delayed.
- **(D)** Mode-change reset suspension state but not the dedup cache, compounding (B).

**Options Considered:**
1. **Fix in place, keep dedup in the controller.** Smallest diff. Leaves the cache semantically owned by the wrong layer — the follower has the tier history but the controller pretends to.
2. **Move the cache to `CaretFollower`, leave bugs (A)-(D) alone.** Matches the spec but doesn't fix the user-visible regressions.
3. **Move the cache and fix the adjacent bugs in one pass.** Bigger diff, but the bugs all stem from the cache being on the wrong side of the seam.

**Decision:** Option 3. `CaretFollower` now owns `lastDeliveredTier: (pid, Tier)?`, computes `tierChanged: Bool` in its `deliver(...)` MainActor helper, and exposes `forceTransitionOnNextDelivery()` for the re-engage case. `PanelPlacementController` consumes `result.tierChanged` directly and clears `statusMessage` whenever it leaves `.followCaret`.

**Rationale:** The follower already knows its tier history (it has to, to deliver `tier` at all). Letting the controller maintain a parallel cache was a small case of duplicated state-machine logic — and once the controller-side cache existed, it created the temptation to "fix" related behavior with controller-side patches that left stale state behind. Moving the cache into the type that owns the transitions made the controller idempotent: it now just reacts to flags on each `Result`, with no follower-history bookkeeping of its own. The bugs vanished without needing dedicated patches for each.

**Consequences:**
- `CaretFollower.Result` gained `tierChanged: Bool`. `readAnchor` was refactored to return a raw `(anchor, tier, focused)` triple; the `Result` is constructed only on `MainActor` so the dedup cache lookup happens in one place.
- `forceTransitionOnNextDelivery()` clears the cache and schedules a refresh — used by `applyForCurrentMode` when entering `.followCaret`, replacing the misleading "force a read by calling `frontmostAppChanged`" pattern.
- `CaretFollower.didTransition(previous:currentPID:currentTier:)` is the pure dedup predicate, made `nonisolated static` for unit-testing without standing up a live `AXObserver`. 5 new tests cover first-delivery, pid-change, tier-change, and same-state-suppression. Total suite is 32/32 passing.
- `PanelPlacementController` lost `lastCaretPID`/`lastCaretTier`. Status-message switching is now a single `if result.tierChanged { switch result.tier ... }` block.
- `.followPointer` now also clears `statusMessage` on entry; previously it didn't.

### 2026-05-29 — Diagnostic logging via `os.Logger` + a plain-text mirror file, separate from `EventStore`

**Context:** A `/minimums` pass flagged that Manifest had no operational/diagnostic logging. The app is permission-heavy (Accessibility + Input Monitoring) and the most likely support burden is "it stopped capturing and I don't know why" — a class of failure that leaves no crash log. `EventStore` already writes JSONL, but that's the *product data* (the captured input events), not the app's own state.

**Options Considered:**
1. **Reuse `EventStore`** — append diagnostic lines into the same JSONL stream. Rejected: pollutes the product log, mixes payloads with operational state, and inherits EventStore's per-day file rotation which isn't what a diagnostic tail wants.
2. **`os.Logger` only** — structured, privacy-aware, visible in Console.app / `log stream`. Good for a developer, but a non-technical user can't easily extract it for a bug report.
3. **A plain-text file only** — easy to attach to a report, but loses Console's live streaming and structured filtering.
4. **`os.Logger` + a plain-text mirror file** (chosen) — both surfaces, one call site.

**Decision:** New `DiagnosticLogger` (`@unchecked Sendable` singleton) that writes to *both* the unified log (subsystem `com.lucesumbrarum.Manifest`, category `diagnostic`) and a plain-text file at `~/Library/Application Support/Manifest/diagnostic.log`. It logs **state, never event payloads** — no keystrokes, no clicked-element titles, no captured app names — so every entry is safe to mark `.public` and is actually readable in Console.

**Rationale:** The two surfaces serve two audiences without duplicating call sites: Console for live debugging during development, the file for "zip this up and send it" support. Keeping it separate from `EventStore` preserves the clean "product data vs. operational state" seam and keeps the privacy story crisp — the product log contains sensitive input, the diagnostic log provably does not. `os.Logger`'s privacy model would otherwise redact dynamic strings by default; logging only non-sensitive state lets us opt into `.public` honestly.

**Consequences:**
- `Services/DiagnosticLogger.swift` added. Thread-safety: file writes serialized on a private `DispatchQueue`, `os.Logger` is `Sendable`, and the `ISO8601DateFormatter` is confined to the queue (it isn't thread-safe). This makes `log(...)` callable from the MainActor, the `EventStore` actor, and the nonisolated `CGEventTap` callback alike — the `@unchecked` invariant is "all mutable file access goes through the queue."
- `fileURL` is exposed so the UI can reveal the log in Finder (wired to a Preferences button).
- Hook points: launch (version + `axTrusted`), capture start/stop, permission-denied (warn), **tap-disabled-by-system re-enable** (warn, `reason=timeout|userInput` — the key "why did it stop" signal), persist failure (replaced EventStore's old stderr write), and both export-failure paths.
- The hot path (the per-event tap callback) deliberately logs nothing except the rare tap-disabled event — no per-keystroke logging, by design.

### 2026-05-29 — Version surfaced in the Settings/About section, not an About window

**Context:** `/minimums` flagged that the marketing version (`0.1.0 (1)`) was set in `project.yml` but invisible anywhere in the UI — so a user reporting a bug couldn't say what version they're on. The standard macOS answer is an About window reached via the App menu.

**Options Considered:**
1. **Standard About window via the App menu.** The conventional spot — but Manifest runs under `.accessory` activation policy, which removes the main menu entirely. There's no App menu to hang an About item off (the same reason `Cmd+,` doesn't work and Settings is reached via a gear button — see 2026-05-28).
2. **Promote to `.regular` policy to get a menu bar.** Rejected: the HUD's whole identity is "no Dock icon, no Cmd+Tab presence." Reversing that for a version string is absurd.
3. **Surface the version in the existing Settings/Preferences scene** (chosen).

**Decision:** Add an **About** section to `PreferencesView` showing `Version 0.1.0 (1)` plus a "Show Diagnostic Log in Finder" button. A new `AppInfo` enum reads version/build/display-name from the bundle Info.plist as the single source of truth, shared by both the footer and the launch log line so they can never drift.

**Rationale:** Settings is already the established secondary surface under `.accessory` (reached via the gear button), so the version belongs there rather than in a window that has no menu to launch it. Bundling the "Show Diagnostic Log" button in the same section makes the new logging discoverable at exactly the moment a user is looking for "how do I report a problem." `AppInfo` as a single accessor avoids the classic bug where a hardcoded UI version string drifts from the build's actual version.

**Consequences:**
- `AppInfo.swift` added (`version`, `build`, `displayName`, `shortVersionString`, `fullVersionString`).
- `PreferencesView` gains an About section; `ManifestApp.applicationDidFinishLaunching` logs `AppInfo.fullVersionString`.
- No About window, no `NSApplication.orderFrontStandardAboutPanel` — consistent with the menu-less `.accessory` design.

---

### 2026-05-29 — License: GPL-3.0 (copyleft), not MIT

**Context:** When publishing to GitHub I (Claude) initially copied an MIT `LICENSE` from the DownKeyCounter/Tachograph template. The repo had actually been created with **GPL-3.0**.

**Decision:** GPL-3.0 is the chosen license. Local `LICENSE` was replaced with the GPL-3.0 text from the remote; the README badge and License section say GPL-3.0.

**Rationale:** Deliberate strong copyleft — any distributed derivative must also be GPL-3.0 and ship its source, so monetization / proprietary forks aren't easy. Do **not** reuse the sibling projects' MIT template for Manifest.

**Consequences:** Future releases stay GPL-3.0. The DownKeyCounter template's MIT default must be overridden for this project.

---

### 2026-05-29 — Direct distribution via notarized DMG from the CLI

**Context:** "Share with others?" → yes. The app was already notarized+stapled (Xcode export), but shipping it as a downloadable DMG is a separate problem: a hand-built DMG is a new file that must itself be signed + notarized + stapled. The account had no usable Developer ID identity and no CLI notarization credential — both were silently handled by Xcode Organizer for previous apps.

**Options Considered:**
1. **Xcode Organizer** — what was used before. Works, but doesn't produce a DMG and hides the credentials, so it doesn't fit a scripted/repeatable CLI release.
2. **Ship a zip of the stapled app** — needs no further notarization (staple travels in the app). Simplest, but no drag-to-Applications UX.
3. **CLI DMG: sign → notarize → staple → gh release** (chosen) — the polished download, fully scriptable.

**Decision:** Create a **Developer ID Application** cert (login keychain), store a **notarytool keychain profile `Manifest`** (ASC API key, Developer role), and run the chain via `scripts/package-dmg.sh`. v1.0.0 shipped this way: github.com/Xpycode/Manifest/releases/tag/v1.0.0.

**Rationale:** A scripted CLI path makes every future release one command and keeps the credentials/cert documented (doc `61_distribution-notarization.md`) instead of locked inside Xcode's cache. Developer ID is the correct identity for notarized direct download (Apple Distribution is App-Store-only).

**Consequences:**
- New cert `Developer ID Application: GREGOR MÜLLER (FDMSRXXN73)` in login keychain; notarytool profile `Manifest` cached.
- `scripts/package-dmg.sh` + Directions doc `61` capture the workflow and gotchas (`.p12` → login keychain not iCloud / `OSStatus -26276`; Managed cert lacks local key; App-Store certs ≠ Developer ID).
- Distribution phase is no longer "parked" — it's an operational, repeatable step.

---
*Add decisions as they are made. Future-you will thank present-you.*
