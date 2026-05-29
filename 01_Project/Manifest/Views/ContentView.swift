import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var vm: EventStreamViewModel
    /// SwiftUI's macOS 14+ environment opener for the `Settings { ... }`
    /// scene. Cmd+, doesn't work under `.accessory` activation policy (no
    /// main menu exists to route the shortcut to), so the gear button in the
    /// expanded header is the actual entry point.
    @Environment(\.openSettings) private var openSettings

    /// Panel size targets. Compact = single-row HUD strip; expanded = full list.
    /// Kept in sync with the SwiftUI `.frame(...)` so the imperative
    /// `setFrame` on the NSPanel matches the SwiftUI ideal size.
    private static let expandedSize = CGSize(width: 520, height: 360)
    /// Compact width matches expanded so toggling never visually jumps the
    /// panel's horizontal extent — only the height collapses.
    private static let compactSize = CGSize(width: 520, height: 32)

    var body: some View {
        Group {
            if vm.isCompact {
                compactBody
            } else {
                expandedBody
            }
        }
        .frame(
            minWidth: 480,
            minHeight: vm.isCompact ? Self.compactSize.height : 320
        )
        .background(.ultraThinMaterial)
        // Both modes get rounded corners — the panel is borderless, so the
        // SwiftUI clip IS the visible window shape. Compact is tighter
        // (8 pt) so the HUD strip reads as a chip; expanded uses the same
        // ~12 pt radius as a standard macOS panel.
        .clipShape(RoundedRectangle(cornerRadius: vm.isCompact ? 8 : 12, style: .continuous))
        .onChange(of: vm.isCompact) { _, isCompact in
            resizePanel(toCompact: isCompact)
        }
        // First render after launch: the panel is always created at the
        // 520×360 expanded contentRect (FloatingPanel.init can't yet read the
        // VM), so if `isCompact` was persisted as true we'd otherwise keep a
        // 360 pt tall window whose visible content is just the 32 pt strip —
        // making the lower 328 pt a ghost hit-area that swallows drags.
        // Sync the panel size to the VM state once, after the view is on
        // screen and the panel exists in NSApp.windows.
        .onAppear {
            resizePanel(toCompact: vm.isCompact)
        }
    }

    // MARK: - Expanded

    private var expandedBody: some View {
        VStack(spacing: 0) {
            expandedHeader
            Divider()
            eventList
            Divider()
            footer
        }
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            statusDot
            Text("Manifest")
                .font(.system(size: 12, weight: .bold, design: .rounded))
            Text(vm.isCapturing ? "capturing" : "stopped")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer()

            startStopButton

            Button("Clear", action: vm.clear)
                .controlSize(.small)
                .disabled(vm.events.isEmpty)

            Menu("Export") {
                Button("Export CSV…", action: vm.exportCSV)
                Button("Export JSON…", action: vm.exportJSON)
            }
            .controlSize(.small)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(vm.events.isEmpty)

            settingsButton
            compactToggle
            quitButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var eventList: some View {
        if vm.events.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: vm.permissionGranted ? "keyboard" : "lock.shield")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if !vm.permissionGranted {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.events) { event in
                        EventRowView(event: event)
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if vm.permissionGranted {
            return "Waiting for input.\nPress any key, click, or scroll."
        }
        return "Manifest needs Accessibility permission to observe input events."
    }

    private var footer: some View {
        HStack {
            Text(vm.statusMessage ?? "\(vm.events.count) events captured")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Compact

    /// Single-row HUD: dot + Start/Stop + most-recent input + expand chevron.
    /// Designed for screencasts where the full list is noise but the
    /// presenter still wants a "what did I just press?" readout on-screen.
    private var compactBody: some View {
        HStack(spacing: 8) {
            statusDot
            startStopButton

            if let latest = vm.events.first {
                KindBadge(kind: latest.kind)
                Text(latest.label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let app = latest.appName ?? latest.bundleID {
                    Text(app)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            } else {
                Text(vm.isCapturing ? "waiting for input…" : "stopped")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            compactToggle
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Shared bits

    private var statusDot: some View {
        Circle()
            .fill(vm.isCapturing ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
    }

    private var startStopButton: some View {
        Button(vm.isCapturing ? "Stop" : "Start") {
            if vm.isCapturing { vm.stop() } else { vm.start() }
        }
        .controlSize(.small)
    }

    /// Replacement for the system close button we lost by going borderless.
    /// Lives only in the expanded header — collapsing to compact is the
    /// way to "hide" the HUD without quitting; expand again to access ×.
    /// No Cmd+Q binding and no menu bar status item: the panel is
    /// `.nonactivatingPanel` under `.accessory` policy, so the OS routes
    /// Cmd+Q to the active app, and the status item was getting eaten by
    /// the user's menu bar manager (Barbee) despite being created. The ×
    /// click is the single, honest quit path.
    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "xmark")
                .frame(width: 18, height: 14)
        }
        .controlSize(.small)
        .help("Quit Manifest")
    }

    /// Opens the SwiftUI Settings scene. We have to activate the app first —
    /// under `.accessory` policy the Settings window won't take focus on its
    /// own. `NSApp.activate` is the documented entry point for this.
    private var settingsButton: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 18, height: 14)
        }
        .controlSize(.small)
        .help("Settings (placement, etc.)")
    }

    private var compactToggle: some View {
        Button {
            vm.isCompact.toggle()
        } label: {
            Image(systemName: vm.isCompact ? "chevron.down" : "chevron.up")
                .frame(width: 18, height: 14)
        }
        .controlSize(.small)
        .help(vm.isCompact ? "Expand panel" : "Collapse to header")
    }

    // MARK: - Panel resize

    /// Resize the always-borderless panel between compact strip and full
    /// list. Top edge is held stable so the user's on-screen position
    /// doesn't jump when collapsing.
    private func resizePanel(toCompact: Bool) {
        guard let panel = NSApp.windows.compactMap({ $0 as? FloatingPanel }).first else { return }
        let target = toCompact ? Self.compactSize : Self.expandedSize
        var frame = panel.frame
        let topY = frame.origin.y + frame.size.height
        frame.size = target
        frame.origin.y = topY - target.height

        // Guarantee the post-resize frame still intersects a visible screen.
        // The pre-resize frame may already be mostly off-screen — e.g. a
        // saved position where the expanded panel's top edge sat above the
        // menu bar. Preserving that top through a compact collapse would put
        // the much shorter strip entirely off-screen and lose the HUD.
        // Falling back to a centered position on the main visibleFrame keeps
        // the panel reachable.
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !onScreen, let vf = NSScreen.main?.visibleFrame {
            frame.origin.x = vf.midX - target.width / 2
            frame.origin.y = vf.midY - target.height / 2
        }

        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }
}
