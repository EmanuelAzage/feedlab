import Foundation

/// Buffers events per item and folds each item view into a record when it ends.
///
/// An actor because events arrive from every queue AVFoundation feels like using. That hop is free
/// of measurement consequence: timestamps are stamped at the callback, so delivery can be as late
/// as it likes without moving a number.
///
/// Raw events are retained for completed items as well as the folded record. That is deliberate —
/// it is what makes a metric *definition* change re-derivable from runs already performed, rather
/// than requiring the runs to be repeated. `MetricsEngine` is a pure function of these.
actor SessionRecorder {
    private(set) var arm: String
    private var pending: [String: [PlaybackEvent]] = [:]
    private(set) var records: [PlaybackRecord] = []
    private var archivedEvents: [String: [PlaybackEvent]] = [:]
    private var startedAt = Date()

    init(arm: String) {
        self.arm = arm
    }

    /// Discards everything and starts over. Selecting an arm resets the session
    /// (`docs/experiment-harness.md`) — comparing across a mid-session arm change would be
    /// comparing two different things under one label.
    func reset(arm: String) {
        self.arm = arm
        pending.removeAll()
        records.removeAll()
        archivedEvents.removeAll()
        startedAt = Date()
    }

    func record(_ event: PlaybackEvent) {
        pending[event.itemID, default: []].append(event)
        // A release closes the item view; fold it now so the buffer does not grow across a session.
        if event.kind == .itemReleased {
            finalize(itemID: event.itemID)
        }
    }

    /// Folds an item's buffered events into a record and archives them.
    @discardableResult
    func finalize(itemID: String) -> PlaybackRecord? {
        guard let events = pending.removeValue(forKey: itemID), !events.isEmpty else { return nil }
        let record = MetricsEngine.record(from: events, itemID: itemID, arm: arm)
        records.append(record)
        archivedEvents[itemID] = events
        return record
    }

    /// The in-flight view, folded as it stands. Feeds the live HUD, which must be able to show a
    /// stall while it is still happening rather than only after the item is released.
    func inFlightRecord(for itemID: String) -> PlaybackRecord? {
        guard let events = pending[itemID], !events.isEmpty else { return nil }
        return MetricsEngine.record(from: events, itemID: itemID, arm: arm)
    }

    func summary(peakMemoryBytes: UInt64 = 0) -> SessionSummary {
        SessionSummary(
            arm: arm,
            records: records,
            peakMemoryBytes: peakMemoryBytes,
            startedAt: startedAt,
            endedAt: Date()
        )
    }

    /// The raw stream for an item, retained so records can be re-derived if a definition changes.
    func events(for itemID: String) -> [PlaybackEvent] {
        archivedEvents[itemID] ?? pending[itemID] ?? []
    }

    /// Every closed item view's events, for persistence.
    ///
    /// Pending items are excluded deliberately: an item view that has not been released has no
    /// record, so persisting its half-stream would store events that no record accounts for — and
    /// the whole point of keeping events is that re-folding them reproduces the records.
    var allArchivedEvents: [String: [PlaybackEvent]] {
        archivedEvents
    }
}
