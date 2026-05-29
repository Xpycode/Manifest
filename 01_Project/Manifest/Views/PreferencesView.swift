import AppKit
import SwiftUI

/// Settings scene content. Cmd+, opens this under SwiftUI's `Settings { ... }`
/// scene (see `ManifestApp.swift`). Lives in its own window — the HUD itself
/// stays uncluttered.
///
/// Live edit: every property here is `@Bindable` on the VM, so changes flow
/// `View → VM.didSet → UserDefaults` and `View → VM → Observation →
/// PanelPlacementController.modeOrOffsetChanged()` — no save button.
struct PreferencesView: View {
    @Bindable var vm: EventStreamViewModel

    var body: some View {
        Form {
            Section("Placement") {
                Picker("Mode", selection: $vm.placementMode) {
                    Text("Pinned").tag(PanelPlacement.pinned)
                    Text("Follow pointer").tag(PanelPlacement.followPointer)
                    Text("Follow caret").tag(PanelPlacement.followCaret)
                }
                .pickerStyle(.segmented)

                if vm.placementMode != .pinned {
                    Stepper(
                        "Horizontal offset: \(Int(vm.placementOffset.dx)) pt",
                        value: $vm.placementOffset.dx,
                        in: PanelOffset.range,
                        step: PanelOffset.step
                    )
                    Stepper(
                        "Vertical offset: \(Int(vm.placementOffset.dy)) pt",
                        value: $vm.placementOffset.dy,
                        in: PanelOffset.range,
                        step: PanelOffset.step
                    )
                    Toggle(
                        "Flip near screen edges",
                        isOn: $vm.placementOffset.flipNearEdges
                    )
                }

                if vm.placementMode == .followCaret {
                    Text("Some apps (Electron-based editors, Terminal, web text inputs) don't expose caret bounds — the HUD will dock to the focused text field instead, or freeze in place if even that isn't available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("About") {
                LabeledContent("Version", value: AppInfo.shortVersionString)
                if let logURL = DiagnosticLogger.shared.fileURL {
                    Button("Show Diagnostic Log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding(.vertical, 8)
    }
}
