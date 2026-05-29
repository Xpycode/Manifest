# Manifest — Claude Context

> Floating macOS HUD that surfaces keyboard, mouse, scroll, and app-switch events with timestamps + the app that was frontmost at the moment of input.

## Files to Read First

1. `docs/PROJECT_STATE.md` — current focus, blockers, status
2. `docs/decisions.md` — WHY behind architectural choices
3. `docs/sessions/_index.md` — recent session logs
4. `01_Project/Manifest/ManifestApp.swift` — app entry point
5. `01_Project/Manifest/Services/EventTapService.swift` — input capture core

## Quick Facts

| Aspect | Value |
|--------|-------|
| **Type** | macOS app |
| **Language** | Swift 6 (strict concurrency) |
| **UI Framework** | SwiftUI + AppKit (NSPanel for floating HUD) |
| **Min Deployment** | macOS 15.0 |
| **Architecture** | MVVM — services own capture, ViewModel owns rolling event list, View is dumb |
| **Persistence** | JSONL append-only at `~/Library/Application Support/Manifest/` |
| **Project file** | XcodeGen (`01_Project/project.yml`) — regenerate with `cd 01_Project && xcodegen` |
| **Bundle ID** | `com.lucesumbrarum.Manifest` |
| **Team** | `FDMSRXXN73` (Personal Team — no entitlements requiring paid team) |

## Tech Stack & Patterns

- `CGEventTap` (.cgSessionEventTap, .listenOnly) on the main run loop — keys, mouse, scroll.
- `NSWorkspace.shared.notificationCenter` — `didActivateApplicationNotification` for app-switch rows.
- `AXUIElementCopyElementAtPosition` (off-main worker) — patch mouse rows with AX role/title.
- `FrontmostAppMonitor` — keeps the latest bundle ID as a lock-free read for the C tap callback.
- `NSPanel` with `.floating` window level + `.nonactivatingPanel` style — HUD that never steals focus.

**Provenance:** the core pipeline is copied from `~/ProgrammingProjects/1-macOS/DownKeyCounter`. See `docs/decisions.md` 2026-05-27 (DownKeyCounter adoption) for why and what gets dropped.

## Critical Rules

### TCC permissions
- App requires **Accessibility** (for `CGEventTap`) and **Input Monitoring** (for raw key codes).
- First launch shows an in-app banner with a "Open Settings" deeplink; never silently fail.

### Threading
- Services are `@MainActor`-bound; the C tap callback runs on the main run loop already (`CFRunLoopGetMain()`), so the trampoline calls `nonisolated` methods that read main-thread-confined state.
- AX lookups run on a background `DispatchQueue` and post results back via a continuation.
- ViewModels are `@MainActor @Observable`.

### Privacy
- Persistent log is local-only. Document in README that it contains keystrokes; do not auto-upload.
- Secure-input fields (`NSSecureTextField`) are detected via `IsSecureEventInputEnabled()` — events are dropped at the service layer, not just hidden in the UI.

### Coordinate system
- `CGEvent.location` is in screen coordinates, top-left origin, points (not pixels). Multi-display setups produce negative coords on the left/upper monitors — pass through verbatim.

## Build & Run

```bash
# Regenerate Xcode project after changes to project.yml
cd 01_Project && xcodegen

# Clean + build + launch (matches global Xcode discipline)
killall Manifest 2>/dev/null || true
xcodebuild -project 01_Project/Manifest.xcodeproj -scheme Manifest -destination 'platform=macOS' clean build
open ~/Library/Developer/Xcode/DerivedData/Manifest-*/Build/Products/Debug/Manifest.app
```

## Reference Code

- DownKeyCounter `Services/EventTapService.swift` — the pattern for the C tap callback + `nonisolated(unsafe)` discipline.
- DownKeyCounter `Services/AXElementLookup.swift` — off-main AX worker with soft deadlines.
- DownKeyCounter `Services/FrontmostAppMonitor.swift` — lock-free frontmost-app snapshot.

## Session Protocol

1. Read this file + `docs/PROJECT_STATE.md`.
2. Confirm the task before coding.
3. After changes, update `docs/sessions/YYYY-MM-DD.md` via `/log`.
4. Record decisions in `docs/decisions.md` via `/decide`.
