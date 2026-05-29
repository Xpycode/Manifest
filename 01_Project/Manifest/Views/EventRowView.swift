import SwiftUI

struct EventRowView: View {
    let event: InputEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(localTime)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            KindBadge(kind: event.kind)

            Text(event.label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)

            if let element = Self.formatElement(role: event.axRole, title: event.axTitle) {
                Text("→ \(element)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Text(targetSummary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var localTime: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: event.timestamp)
    }

    /// "Safari" or "Safari @ 1240,380" depending on whether we have coords.
    private var targetSummary: String {
        let app = event.appName ?? event.bundleID ?? "—"
        if let point = event.point {
            return "\(app) @ \(Int(point.x)),\(Int(point.y))"
        }
        return app
    }

    /// Compact AX hint: `Button "Quit"`, `TextField`, or nil. The "AX" prefix
    /// on standard AX role constants (AXButton, AXTextField, AXImage…) is
    /// stripped — it's universal and just adds visual noise. Returns nil
    /// when there's no role to show.
    static func formatElement(role: String?, title: String?) -> String? {
        guard let role else { return nil }
        let cleanRole = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        if let title { return "\(cleanRole) \"\(title)\"" }
        return cleanRole
    }
}

/// Color-coded kind tag (KEY / MOD / MSE / SCR / APP). Shared between the
/// expanded event list and the compact HUD strip so they read as one app.
struct KindBadge: View {
    let kind: InputEvent.Kind

    var body: some View {
        Text(symbol)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var symbol: String {
        switch kind {
        case .key: return "KEY"
        case .modifier: return "MOD"
        case .mouse: return "MSE"
        case .scroll: return "SCR"
        case .appSwitch: return "APP"
        }
    }

    private var color: Color {
        switch kind {
        case .key: return .blue
        case .modifier: return .cyan
        case .mouse: return .orange
        case .scroll: return .purple
        case .appSwitch: return .green
        }
    }
}
