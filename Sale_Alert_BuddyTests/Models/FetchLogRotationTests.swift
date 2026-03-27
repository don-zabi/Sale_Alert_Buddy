import Testing
import Foundation
import CoreData
@testable import Sale_Alert_Buddy

/// Tests FetchLog rotation logic: the 50-log cap on TrackingItem.addFetchLogAndRotate.
struct FetchLogRotationTests {

    // MARK: - Helpers

    /// Returns a fresh background context on the shared in-memory store.
    private func makeContext() -> NSManagedObjectContext {
        TestPersistence.newContext()
    }

    /// Creates a TrackingItem with a unique URL (so tests don't collide).
    private func makeItem(context: NSManagedObjectContext) -> TrackingItem {
        let item = TrackingItem.create(in: context)
        item.originalUrl = "https://example.com/product-\(UUID().uuidString)"
        item.currentUrl = item.originalUrl
        item.domain = "example.com"
        item.baselinePriceDecimal = 1000
        item.baselineCurrency = "JPY"
        return item
    }

    private func addLog(
        to item: TrackingItem,
        context: NSManagedObjectContext,
        note: String? = nil
    ) -> FetchLog {
        let log = FetchLog.create(
            for: item,
            outcome: .success,
            httpStatus: 200,
            errorType: .none,
            extractMethod: .schemaOrg,
            durationMs: 100,
            note: note,
            context: context
        )
        item.addFetchLogAndRotate(log, context: context)
        return log
    }

    // MARK: - Cap Tests

    @Test func after50LogsCountIs50() throws {
        let context = makeContext()
        let item = makeItem(context: context)
        for i in 0..<50 {
            _ = addLog(to: item, context: context, note: "log-\(i)")
        }
        try context.save()

        #expect(item.fetchLogsArray.count == 50)
    }

    @Test func after51LogsCountIsStill50() throws {
        let context = makeContext()
        let item = makeItem(context: context)
        for i in 0..<51 {
            _ = addLog(to: item, context: context, note: "log-\(i)")
        }
        try context.save()

        #expect(item.fetchLogsArray.count == 50)
    }

    @Test func after100LogsCountIsStill50() throws {
        let context = makeContext()
        let item = makeItem(context: context)
        for i in 0..<100 {
            _ = addLog(to: item, context: context, note: "log-\(i)")
        }
        try context.save()

        #expect(item.fetchLogsArray.count == 50)
    }

    // MARK: - Oldest Log Removed

    @Test func oldestLogRemovedWhenLimitExceeded() throws {
        let context = makeContext()
        let item = makeItem(context: context)

        for i in 0..<50 {
            _ = addLog(to: item, context: context, note: "log-\(i)")
        }

        let newestLog = addLog(to: item, context: context, note: "log-50")
        try context.save()

        let logs = item.fetchLogsArray
        #expect(logs.count == 50)

        let notes = logs.compactMap { $0.note }
        #expect(notes.contains("log-50"))
        #expect(!notes.contains("log-0"))
        #expect(logs.contains(newestLog))
    }

    @Test func logsSortedNewestFirst() throws {
        let context = makeContext()
        let item = makeItem(context: context)

        for i in 0..<5 {
            let log = FetchLog(context: context)
            log.id = UUID()
            log.trackingItemId = item.id
            log.timestamp = Date(timeIntervalSinceNow: Double(i) * 60)
            log.fetchOutcome = .success
            log.httpStatus = 200
            log.durationMs = 100
            log.trackingItem = item
            item.addFetchLogAndRotate(log, context: context)
        }

        try context.save()

        let logs = item.fetchLogsArray
        for i in 0..<(logs.count - 1) {
            #expect(logs[i].timestamp >= logs[i + 1].timestamp)
        }
    }

    // MARK: - Boundary: exactly 50 logs

    @Test func exactlyAtCapAllLogsPresent() throws {
        let context = makeContext()
        let item = makeItem(context: context)
        for i in 0..<50 {
            _ = addLog(to: item, context: context, note: "log-\(i)")
        }
        try context.save()

        let notes = item.fetchLogsArray.compactMap { $0.note }
        for i in 0..<50 {
            #expect(notes.contains("log-\(i)"), "Missing log-\(i)")
        }
    }

    // MARK: - Multiple Rotations

    @Test func rotationHappensOnEveryAddAfterCap() throws {
        let context = makeContext()
        let item = makeItem(context: context)

        for i in 0..<50 {
            _ = addLog(to: item, context: context, note: "initial-\(i)")
        }
        for i in 0..<10 {
            _ = addLog(to: item, context: context, note: "extra-\(i)")
        }

        try context.save()

        #expect(item.fetchLogsArray.count == 50)

        let notes = item.fetchLogsArray.compactMap { $0.note }
        for i in 0..<10 {
            #expect(notes.contains("extra-\(i)"), "Missing extra-\(i)")
        }
    }

    // MARK: - Two Items Rotate Independently

    @Test func twoItemsRotateIndependently() throws {
        let context = makeContext()

        let item1 = makeItem(context: context)
        let item2 = makeItem(context: context)

        for i in 0..<51 {
            _ = addLog(to: item1, context: context, note: "a-\(i)")
        }
        for i in 0..<5 {
            _ = addLog(to: item2, context: context, note: "b-\(i)")
        }

        try context.save()

        #expect(item1.fetchLogsArray.count == 50)
        #expect(item2.fetchLogsArray.count == 5)
    }
}
