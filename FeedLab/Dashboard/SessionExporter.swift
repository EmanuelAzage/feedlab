import Foundation

/// Turns stored sessions into CSV and JSON.
///
/// The README's results table is generated from the CSV export rather than typed by hand
/// (`docs/observability.md`), so this is the last point at which a published number can drift from
/// a measured one. It is a pure function of stored sessions for exactly that reason.
///
/// **A nil metric exports as an empty field, never as `0`.** `qoe-metrics.md` makes optional mean
/// "not applicable", and a progressive MP4 written out with `bitrateSwitchCount=0` would read as a
/// flawless ABR result on a stream that has no ladder at all — then be averaged into a table. The
/// same rule that governs the in-memory model has to survive serialisation, and a test pins it.
enum SessionExporter {
    // MARK: - CSV

    /// One row per item view, with its session's identity repeated on each row.
    ///
    /// Flat and denormalised on purpose: the consumer is a spreadsheet or a script generating the
    /// README table, and a join is a step at which the wrong arm can be attached to a number.
    static let csvColumns = [
        "session_id", "arm", "run_started_at", "session_peak_memory_bytes",
        "item_id", "time_to_first_frame_ms", "media_stack_startup_ms",
        "stall_count", "total_stall_duration_s", "watch_duration_s", "rebuffer_ratio",
        "observed_bitrate_bps", "indicated_bitrate_bps", "bitrate_switch_count",
        "dropped_frames", "player_wait_ms", "is_skipped", "error_count"
    ]

    static func csv(from sessions: [StoredSession]) -> String {
        var lines = [csvColumns.joined(separator: ",")]
        let formatter = ISO8601DateFormatter()

        for session in sessions.sorted(by: { $0.summary.startedAt < $1.summary.startedAt }) {
            let summary = session.summary
            for record in summary.records {
                let fields: [String] = [
                    session.id.uuidString,
                    summary.arm,
                    formatter.string(from: summary.startedAt),
                    String(summary.peakMemoryBytes),
                    record.itemID,
                    milliseconds(record.timeToFirstFrame),
                    milliseconds(record.mediaStackStartupTime),
                    String(record.stallCount),
                    seconds(record.totalStallDuration),
                    seconds(record.watchDuration),
                    String(format: "%.4f", record.rebufferRatio),
                    number(record.observedBitrate),
                    number(record.indicatedBitrate),
                    record.bitrateSwitchCount.map(String.init) ?? "",
                    record.droppedFrames.map(String.init) ?? "",
                    milliseconds(record.playerWaitDuration),
                    record.isSkipped ? "true" : "false",
                    String(record.errors.count)
                ]
                lines.append(fields.map(escape).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    /// The full sessions, raw events included — the archival format.
    ///
    /// CSV is for reading and for the README table; this is what makes a run re-derivable if a
    /// metric definition changes, which is the same reason the store keeps events at all.
    static func json(from sessions: [StoredSession]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(sessions)
    }

    // MARK: - Formatting

    /// Empty for nil. The whole point of the type.
    private static func milliseconds(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.1f", $0 * 1000) } ?? ""
    }

    private static func seconds(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.3f", $0) } ?? ""
    }

    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? ""
    }

    /// RFC 4180 quoting. Item ids and arm names are tame today, but a manifest is data and a stray
    /// comma silently shifting every column to its right is a hard failure to notice in a table.
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
