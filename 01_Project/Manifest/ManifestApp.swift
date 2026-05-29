import AppKit
import SwiftUI

@main
struct ManifestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The HUD is provided by AppDelegate via FloatingPanel. The Settings
        // scene gets a real PreferencesView wired to the same ViewModel —
        // SwiftUI binds Cmd+, to it automatically under .accessory policy.
        Settings {
            PreferencesView(vm: appDelegate.viewModel)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    /// Held strongly so it doesn't deallocate after `applicationDidFinishLaunching`.
    private var placementController: PanelPlacementController?
    /// Exposed so the `Settings` scene can bind to the same VM instance the
    /// HUD uses — both must observe the same placement state.
    let viewModel = EventStreamViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLogger.shared.log(
            "launched",
            state: [
                "version": AppInfo.fullVersionString,
                "axTrusted": "\(EventTapService.isAccessibilityTrusted)"
            ]
        )

        // Don't appear in the Cmd+Tab list — we're a HUD.
        NSApp.setActivationPolicy(.accessory)

        let content = ContentView(vm: viewModel)
        let panel = FloatingPanel(rootView: content)
        self.panel = panel

        // Placement controller must exist before makeKeyAndOrderFront so that
        // the first `panelDidMove` notification (which can fire during
        // restoreOriginOrCenter) sees the controller and respects its mode.
        let controller = PanelPlacementController(
            panel: panel,
            vm: viewModel,
            monitor: viewModel.monitor
        )
        panel.placementController = controller
        self.placementController = controller

        panel.makeKeyAndOrderFront(nil)

        viewModel.bootstrap()
        // bootstrap() starts the FrontmostAppMonitor; the controller piggybacks
        // its onSwitch closure, so start it AFTER bootstrap so it can wrap the
        // VM's already-installed onSwitch.
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
