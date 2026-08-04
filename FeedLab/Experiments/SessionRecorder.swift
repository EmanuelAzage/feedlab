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
///
/// **The archive is per item *view*, parallel to `records`, not keyed by item id.** Keyed by id it
/// silently dropped the earlier stream whenever an item was viewed twice — which a run script that
/// scrolls back does constantly. Records kept both views and the event log kept one, so the archive
/// no longer re-folded to the records it was supposed to explain, and the failure was invisible in
/// the summary: only a run whose navigation path was reconstructed from the events showed a gap
/// where the second visit had overwritten the first.
actor SessionRecorder {
    private(set) var arm: String
    private var pending: [String: [PlaybackEvent]] = [:]
    private(set) var records: [PlaybackRecord] = []
    private var archivedViews: [[PlaybackEvent]] = []
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
        archivedViews.removeAll()
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
        // Appended in lockstep with `records`, so `archivedViews[i]` is the stream `records[i]` was
        // folded from. A test pins the correspondence.
        archivedViews.append(events)
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
    ///
    /// The **most recent** closed view of the item, falling back to the one in flight. Callers that
    /// need every view want `allArchivedViews`; this exists for the HUD and for debugging, where
    /// "what happened to the item I am looking at" is the question.
    func events(for itemID: String) -> [PlaybackEvent] {
        if let pending = pending[itemID], !pending.isEmpty { return pending }
        return archivedViews.last { $0.first?.itemID == itemID } ?? []
    }

    /// Every closed item view's events, in view order, for persistence.
    ///
    /// Pending items are excluded deliberately: an item view that has not been released has no
    /// record, so persisting its half-stream would store events that no record accounts for — and
    /// the whole point of keeping events is that re-folding them reproduces the records.
    var allArchivedViews: [[PlaybackEvent]] {
        archivedViews
    }
}
