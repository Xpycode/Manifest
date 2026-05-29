import Foundation

/// Converts `[InputEvent]` to CSV and JSON for on-demand export.
/// Pure functions — no I/O. The caller is responsible for picking a path
/// (typically via `NSSavePanel`) and writing the resulting `Data`.
enum Exporter {
    /// CSV with both local and UTC timestamps. RFC 4180 quoting.
    static func csv(events: [InputEvent], timeZone: TimeZone = .current) -> String {
        let localFmt = DateFormatter()
        localFmt.locale = Locale(identifier: "en_US_POSIX")
        localFmt.timeZone = timeZone
        localFmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let utcFmt = DateFormatter()
        utcFmt.locale = Locale(identifier: "en_US_POSIX")
        utcFmt.timeZone = TimeZone(identifier: "UTC")
        utcFmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"

        var lines: [String] = ["local_time,utc_time,kind,label,bundle_id,app_name,point_x,point_y,scroll_dx,scroll_dy,count,ax_role,ax_title"]
        for event in events {
            let row: [String] = [
                localFmt.string(from: event.timestamp),
                utcFmt.string(from: event.timestamp),
                event.kind.rawValue,
                event.label,
                event.bundleID ?? "",
                event.appName ?? "",
                event.point.map { "\($0.x)" } ?? "",
                event.point.map { "\($0.y)" } ?? "",
                event.scrollDelta.map { "\($0.dx)" } ?? "",
                event.scrollDelta.map { "\($0.dy)" } ?? "",
                "\(event.count)",
                event.axRole ?? "",
                event.axTitle ?? "",
            ]
            lines.append(row.map(csvQuote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// JSON array. `JSONEncoder` ISO8601 dates.
    static func json(events: [InputEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(events)
    }

    private static func csvQuote(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
