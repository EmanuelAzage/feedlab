import Foundation
import Testing

@testable import FeedLab

@Suite("Session store")
struct SessionStoreTests {
    /// A directory of its own per test, so tests cannot see each other's sessions.
    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedLabTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeSession(
        arm: String = "baseline",
        itemID: String = "item-1",
        startedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> StoredSession {
        let events: [PlaybackEvent] = [
            PlaybackEvent(itemID: itemID, timestamp: 0, kind: .itemBecameCurrent),
            PlaybackEvent(itemID: itemID, timestamp: 0.4, kind: .readyForDisplay),
            PlaybackEvent(itemID: itemID, timestamp: 0.4, kind: .playbackStarted),
            PlaybackEvent(itemID: itemID, timestamp: 2.0, kind: .stallBegan),
            PlaybackEvent(itemID: itemID, timestamp: 2.5, kind: .stallEnded),
            PlaybackEvent(
                itemID: itemID,
                timestamp: 3.0,
                kind: .accessLogEntry(AccessLogSnapshot(indicatedBitrate: 1_030_138, observedBitrate: 5_931_000))
            ),
            PlaybackEvent(
                itemID: itemID,
                timestamp: 3.5,
                kind: .errorLogEntry(PlaybackErrorEvent(statusCode: -12_642, domain: "CoreMediaErrorDomain"))
            ),
            PlaybackEvent(itemID: itemID, timestamp: 6.0, kind: .itemReleased)
        ]
        let record = MetricsEngine.record(from: events, itemID: itemID, arm: arm)
        return StoredSession(
            summary: SessionSummary(
                arm: arm,
                records: [record],
                peakMemoryBytes: 28_100_000,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(60)
            ),
            events: [itemID: events]
        )
    }

    // MARK: - Round trip

    @Test("A saved session survives being reloaded")
    func roundTrip() async throws {
        let store = try SessionStore(directory: makeTemporaryDirectory())
        let session = makeSession()

        try await store.save(session)
        let loaded = await store.load()

        #expect(loaded == [session], "a reloaded session must equal what was written")
        try await store.deleteAll()
    }

    @Test("A session written by one store instance is readable by the next")
    func survivesRelaunch() async throws {
        // The acceptance criterion in `build-plan.md`: sessions survive app relaunch. A second
        // store over the same directory is what a relaunch amounts to — nothing is held in memory.
        let directory = makeTemporaryDirectory()
        let session = makeSession()
        try await SessionStore(directory: directory).save(session)

        let reopened = try SessionStore(directory: directory)
        let loaded = await reopened.load()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == session.id)
        try await reopened.deleteAll()
    }

    @Test("Records re-derive from the persisted events")
    func recordsAreAProjectionOfPersistedEvents() async throws {
        // The reason events are stored at all. If this holds, a metric definition can change and be
        // re-derived against runs already performed, instead of the runs having to be repeated —
        // and a device afternoon is the most expensive thing this project produces.
        let store = try SessionStore(directory: makeTemporaryDirectory())
        try await store.save(makeSession())

        let loaded = try #require(await store.load().first)
        let record = try #require(loaded.summary.records.first)
        let events = try #require(loaded.events[record.itemID])

        let refolded = MetricsEngine.record(from: events, itemID: record.itemID, arm: loaded.summary.arm)

        #expect(refolded == record, "re-folding persisted events must reproduce the persisted record")
        try await store.deleteAll()
    }

    // MARK: - Multiple sessions

    @Test("Sessions come back newest first")
    func sortedNewestFirst() async throws {
        let store = try SessionStore(directory: makeTemporaryDirectory())
        let older = makeSession(arm: "baseline", startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeSession(arm: "preload1", startedAt: Date(timeIntervalSince1970: 9_000))

        try await store.save(older)
        try await store.save(newer)
        let loaded = await store.load()

        #expect(loaded.map(\.summary.arm) == ["preload1", "baseline"])
        try await store.deleteAll()
    }

    @Test("Sessions are separate files, so one arm's run cannot overwrite another's")
    func sessionsDoNotOverwriteEachOther() async throws {
        let store = try SessionStore(directory: makeTemporaryDirectory())
        for arm in ["baseline", "preload1", "preload3-capped", "window", "pool-unbounded"] {
            try await store.save(makeSession(arm: arm, itemID: "item-\(arm)"))
        }

        #expect(await store.count() == 5)
        try await store.deleteAll()
    }

    // MARK: - Failure modes

    @Test("An unreadable file is skipped, and the rest still load")
    func corruptFileDoesNotHideTheOthers() async throws {
        // The reason for one file per session. Losing a session to a truncated write is a bad day;
        // losing the whole study to it would mean re-running every arm on a device.
        let directory = makeTemporaryDirectory()
        let store = try SessionStore(directory: directory)
        try await store.save(makeSession(arm: "baseline"))
        try await store.save(makeSession(arm: "preload1", itemID: "item-2"))

        let corrupt = directory.appendingPathComponent("\(UUID().uuidString).session.json")
        try Data("{ not json".utf8).write(to: corrupt)

        let loaded = await store.load()

        #expect(loaded.count == 2, "the readable sessions must survive an unreadable neighbour")
        try await store.deleteAll()
    }

    @Test("Loading a store that was never written returns nothing rather than failing")
    func emptyStoreLoadsEmpty() async throws {
        let store = try SessionStore(directory: makeTemporaryDirectory())
        #expect(await store.load().isEmpty)
    }

    @Test("Deleting removes only the session asked for")
    func deleteIsTargeted() async throws {
        let store = try SessionStore(directory: makeTemporaryDirectory())
        let kept = makeSession(arm: "baseline")
        let removed = makeSession(arm: "preload1", itemID: "item-2")
        try await store.save(kept)
        try await store.save(removed)

        try await store.delete(id: removed.id)
        let loaded = await store.load()

        #expect(loaded.map(\.id) == [kept.id])
        try await store.deleteAll()
    }

    // MARK: - Encoding shape

    @Test("Optional metrics survive as null rather than collapsing to zero")
    func optionalsDoNotBecomeZero() async throws {
        // `qoe-metrics.md`: optional means "not applicable", never zero. A progressive asset has no
        // ladder, and a persisted `bitrateSwitchCount: 0` would read as a flawless ABR result.
        let store = try SessionStore(directory: makeTemporaryDirectory())
        let itemID = "progressive-item"
        let events: [PlaybackEvent] = [
            PlaybackEvent(itemID: itemID, timestamp: 0, kind: .itemBecameCurrent),
            PlaybackEvent(itemID: itemID, timestamp: 5, kind: .itemReleased)
        ]
        let record = MetricsEngine.record(from: events, itemID: itemID, arm: "baseline")
        #expect(record.bitrateSwitchCount == nil, "precondition: no ladder means nil, not zero")
        #expect(record.timeToFirstFrame == nil, "precondition: never rendered means nil, not zero")

        try await store.save(
            StoredSession(summary: SessionSummary(arm: "baseline", records: [record]), events: [itemID: events])
        )
        let reloaded = try #require(await store.load().first?.summary.records.first)

        #expect(reloaded.bitrateSwitchCount == nil)
        #expect(reloaded.timeToFirstFrame == nil)
        try await store.deleteAll()
    }
}
