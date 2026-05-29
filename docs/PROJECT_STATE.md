# Project State

> **Size limit: <100 lines.** This is a digest, not an archive. Details go in session logs.

## Identity
- **Project:** Manifest
- **One-liner:** Floating macOS HUD that shows keyboard, mouse, scroll, and app-switch events with timestamps + per-event target app
- **Tags:** macOS, SwiftUI, CGEventTap, Accessibility, HUD, screencast-utility
- **Started:** 2026-05-27

## Current Position
- **Funnel:** build
- **Phase:** implementation
- **Focus:** **Ship-ready for personal use.** All app-minimums gaps closed (version in Preferences, `DiagnosticLogger`, app icon) and the final manual verification passed — tier-3 caret freeze, secure-input freeze, and drag-during-follow resume gate all confirmed by hand on a clean build. Polish → Ship gate closed. Remaining work is all Distribution-phase (notarization / Sparkle / DMG), parked behind "share with others?".
- **Status:** active
- **Last updated:** 2026-05-29

## Funnel Progress

| Funnel | Status | Gate |
|--------|--------|------|
| **Define** | done | One-liner + scope locked (keys + clicks + scroll + app-switch, floating panel, persistent log + export, local + UTC timestamps) |
| **Plan** | done | Lean on DownKeyCounter's CGEventTap pipeline; XcodeGen for project file |
| **Build** | active | First vertical slice working; iterating on HUD UX |

## Phase Progress
```
[################....] 80% - feature-complete + polished; ship-ready for personal use (Distribution deferred)
```

| Phase | Status | Tasks |
|-------|--------|-------|
| Discovery | done | ✓ Scope interview (window style, display mode, event types) |
| Planning | done | ✓ Architecture mirrors DownKeyCounter |
| Implementation | **active** | ✓ Capture pipeline + ✓ floating panel + ✓ compact mode + ✓ scroll coalescing + ✓ export + ✓ AX enrichment + ✓ own-panel filter + ✓ `isCompact` persistence + ✓ panel-position persistence + ✓ AX-PID click re-stamp + ✓ `performDrag` window drag + ✓ placement modes (pinned / followPointer / followCaret) + ✓ Settings scene + ✓ caret `statusMessage` tier-transition dedup |
| Polish | **done** | ✓ version visible (Preferences About) + ✓ diagnostic logging (os.Logger + log file) + ✓ app icon ("Input Ripple", compiled into Assets.car) + ✓ manual verification (tier-3 caret freeze / secure-input freeze / drag-during-follow resume gate all pass) |

## Readiness

| Dimension | Status | Notes |
|-----------|--------|-------|
| Features | 🟢 v1+ | keys, mouse, scroll, app-switch, compact HUD, CSV/JSON export, AX role/title enrichment, own-panel filtering, follow-pointer / follow-caret placement |
| UI/Polish | 🟢 | Borderless panel + SwiftUI chrome; isCompact + panel position + placement mode/offset persist; real Settings scene reachable via gear button; version shown in About; "Show Diagnostic Log" button; app icon ("Input Ripple") |
| Infrastructure | 🟢 | `DiagnosticLogger` (os.Logger + `~/Library/Application Support/Manifest/diagnostic.log`), state-not-payloads; preferences via @AppStorage; permission/export error feedback |
| Testing | 🔶 WIP | 32 unit tests (KeyNameMapper + AXElementLookup fallback/deadline/cap + PlacementMath flip/clamp/round-trip + CaretFollower tier-transition dedup); no integration tests yet |
| Docs | 🔶 WIP | Directions copy in place; session log started |
| Distribution | ⚪ — | local dev only |

## Validation Gates
- [x] **Define → Plan**: One-liner + scope confirmed via interview
- [x] **Plan → Build**: Reference impl identified (DownKeyCounter)
- [x] **Build → Ship**: First clean build + smoke capture
- [x] **Polish → Ship**: manual verification passed (tier-3 caret freeze / secure-input freeze / drag-during-follow resume gate). App icon, version visibility, diagnostic logging done; Preferences + panel position persist; global hotkey deferred as optional. README sanity-check optional.

## Active Decisions
- 2026-05-27: **Floating always-on-top panel** (not menu bar). NSPanel-backed `.floating` level so it survives Cmd+Tab without losing focus, ideal for screencasts/demos.
- 2026-05-27: **Capture all four event classes for v1**: keys, app-switches (NSWorkspace), mouse clicks (CGEventTap + AX hit-test), scroll/trackpad gestures.
- 2026-05-27: **Persistent log + CSV/JSON export**, with both local and UTC timestamps per row.
- 2026-05-27: **Lean heavily on DownKeyCounter**: copy `EventTapService`/`AXElementLookup`/`FrontmostAppMonitor`/`ModifierTapDetector`/`KeyNameMapper` patterns rather than reinventing.
- 2026-05-27: **XcodeGen + Swift 6 strict concurrency**, matching DownKeyCounter's `project.yml`.
- 2026-05-27: **Always-borderless `FloatingPanel`; SwiftUI draws all chrome.** Runtime `styleMask` swaps leave `.fullSizeContentView` broken (transparent titlebar gap on re-expand). Borderless + SwiftUI `.background(.ultraThinMaterial) + .clipShape` for both modes; lost system traffic lights replaced by a SwiftUI × button.
- 2026-05-27: **`applicationShouldTerminateAfterLastWindowClosed = false`** for the HUD. Required because `.utilityWindow` floating panels aren't counted as visible windows by NSApp under `.accessory` activation — dismissing NSSavePanel was terminating the app.
- 2026-05-27: **Frontmost app tracked via KVO on `NSWorkspace.shared.frontmostApplication`**, not `didActivateApplicationNotification`. The notification drops activations intermittently for `.accessory`-policy observers and was stamping every captured event with a stale bundleID.
- 2026-05-27: **Quit is × button only.** No Cmd+Q (`.accessory` + `.nonactivatingPanel` makes it route to the active app). No status bar item (was correctly registered but invisible in practice under user's menu bar manager). Expand from compact to reach ×.
- 2026-05-27: **`isCompact` persists via UserDefaults** (`hud.isCompact` key). Same `hud.*` namespace hosts panel-position persistence.
- 2026-05-27: **Panel top-left origin persists** under `hud.frame.originX/Y`. Restored in `FloatingPanel.init` only if the saved origin still lands on a connected screen (`NSScreen.visibleFrame.intersects`), else `center()`. Saved on every `NSWindow.didMoveNotification`. Size stays SwiftUI-driven; we deliberately don't persist it.
- 2026-05-28: **Expanded view stays fixed at 520×360 — no resize.** Compact toggle already gives a 2-state size control; adding free-form resize would re-introduce styleMask risk (regressing yesterday's borderless fix) or break the "compact width = expanded width" invariant. If pain shows up, follow-up is discrete heights (header-driven), not `.resizable`.
- 2026-05-27: **AX role/title enrichment** of mouse rows via off-main `AXElementLookup` worker (serial queue, 0.25 s AX-IPC timeout, 2 s per-request deadline, 20-item FIFO cap). Recursion guard is geometric (`hitTestOwnPanel`), not bundleID — `.nonactivatingPanel` makes the bundleID guard miss the crash case. Live-display only; not persisted to JSONL.
- 2026-05-27: **Own-panel mouse events dropped entirely** from live list, JSONL, and AX enqueue. Manifest is a record of input sent to *other* apps; HUD-control clicks are meta-noise.
- 2026-05-28: **Click-attribution race repaired via AX element PID.** AX worker passes `pid_t` through `onResult`; `EventStreamViewModel.applyAX` resolves PID → bundleID via `NSRunningApplication` and re-stamps `bundleID`/`appName` on the in-memory row when they disagree with the racy frontmost snapshot. Live-only — JSONL stays append-only and keeps the original tap-time stamp (same policy as AX role/title enrichment).
- 2026-05-28: **Window drag via explicit `performDrag(with:)`, not `isMovableByWindowBackground`.** The auto-heuristic intermittently lost the drag on the 32 pt compact strip (cursor exited the panel before AppKit anchored the drag, subsequent mouseDragged events silently dropped). `mouseDown` → `performDrag(with:)` captures the mouse globally and survives the cursor leaving the panel. Also added `.onAppear` size sync so launch with persisted `isCompact=true` shrinks the window (no ghost hit-area) and an on-screen guard in `resizePanel` so collapsing a panel whose top is already above the menu bar can't push it entirely into the void.
- 2026-05-28: **Three HUD placement modes — pinned / followPointer / followCaret — with live-editable offset.** Pointer: `CADisplayLink` + `NSEvent.mouseLocation`. Caret: `AXObserver` + `kAXBoundsForRangeParameterizedAttribute` (length=1). Persistence under `hud.placement.*`. Full spec at `docs/specs/placement.md`.
- 2026-05-28: **Caret-missing fallback chain: caret → focused-field rect → freeze (NOT pointer).** Preserves "near typing" intent when AX can't deliver per-character bounds (Electron, Terminal, web fields without VoiceOver). Pointer would silently teleport the HUD across the screen, violating the user's explicit mode choice.
- 2026-05-28: **Cmd+, doesn't work under `.accessory` policy** — no main menu exists to route the shortcut to. Settings is opened via a gear button in the expanded header (`NSApp.activate(ignoringOtherApps: true)` + `@Environment(\.openSettings)`). SwiftUI `Settings { ... }` scene retained for the window itself.
- 2026-05-28: **Approach-freeze on current HUD frame + 12 pt pad (not candidate frame).** Original §6.1 "if candidate frame contains pointer, drop update" never fires with non-zero offset — the HUD fled the cursor forever. Read `NSEvent.mouseLocation` at every apply step; if cursor is within the *current* HUD frame inflated by 12 pt, drop the update so the user can land a click on the chrome.
- 2026-05-29: **Diagnostic logging via `os.Logger` + a plain-text mirror file**, separate from `EventStore`. `DiagnosticLogger` logs the app's *operational* state (TCC trust, tap lifecycle, system tap-disable, persist/export failures) — state, never event payloads, so all entries are `.public` and Console-readable. Mirror file at `~/Library/Application Support/Manifest/diagnostic.log` lets users attach it to a bug report without Console. `@unchecked Sendable` with queue-serialized writes so it's callable from MainActor, the `EventStore` actor, and the nonisolated tap callback.
- 2026-05-29: **Version surfaced in the Settings/About section, not an About window.** No App menu exists under `.accessory` policy to hang a standard About item off — consistent with the 2026-05-28 "gear button, not Cmd+," decision. `AppInfo` reads version/build from the bundle as the single source for both the footer and the launch log.
- 2026-05-28: **`statusMessage` tier-transition dedup lives in `CaretFollower`, not the controller.** `Result` carries a computed `tierChanged: Bool`; controller fires status messages only on transitions. Same pass fixed four bugs: stale "Caret bounds unavailable…" persisting after switching to `.followPointer`, re-entering `.followCaret` not re-surfacing the warning, the broken "force a read by calling `frontmostAppChanged`" pattern (early-outs on same PID), and dedup state surviving mode change. Re-entry now uses `caret.forceTransitionOnNextDelivery()`. 32/32 tests pass.

## Blockers
- TCC permissions (Accessibility + Input Monitoring) must be granted manually on first launch — documented in README and surfaced via in-app banner.

## Next Actions

**Core is "feels finished" — no required work remaining for personal use.**

**Optional polish (deferred unless asked):** refine icon art via a real image generator (current `Manifest-icon.svg` is a hand-built first pass); README sanity-check; tune `approachPad = 12 pt`; tier-2 Electron verification; global compact-toggle hotkey; defer mouse-row JSONL append until AX resolves.

**Distribution phase (the next real milestone, gated by "share with others?"):** notarization, Sparkle auto-update, DMG packaging.

## Infrastructure
- **Reference codebase:** `~/ProgrammingProjects/1-macOS/DownKeyCounter`
- **Tooling:** xcodegen (homebrew), Xcode 16+, Swift 6, macOS 15+
- **Bundle prefix:** `com.lucesumbrarum.Manifest`
- **Team:** `FDMSRXXN73` (Personal Team — sufficient, no iCloud/CloudKit needed)

## Resume
Most recent: [2026-05-29](sessions/2026-05-29.md) — `/minimums` check closed all 3 baseline gaps (version in Preferences About via `AppInfo`, `DiagnosticLogger`, app icon "Input Ripple"); then **manual verification passed on a clean build** — tier-3 caret freeze, secure-input freeze, and drag-during-follow resume gate all confirmed by hand. **Polish → Ship gate closed; core feels finished for personal use.** Distribution (notarization / Sparkle / DMG) is the next milestone, parked behind "share with others?". Prior: [2026-05-28](sessions/2026-05-28.md) — AX-PID click re-stamp + `performDrag` drag + placement modes + statusMessage dedup + rename to Manifest complete.

---
*Updated by Claude. Source of truth for project position.*
