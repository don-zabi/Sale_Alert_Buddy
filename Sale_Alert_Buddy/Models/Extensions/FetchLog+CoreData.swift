import Foundation
import CoreData

@objc(FetchLog)
public class FetchLog: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var trackingItemId: UUID
    @NSManaged public var timestamp: Date
    @NSManaged public var outcome: Int16
    @NSManaged public var httpStatus: Int16
    @NSManaged public var errorType: Int16
    @NSManaged public var extractMethod: Int16
    @NSManaged public var durationMs: Int32
    @NSManaged public var note: String?
    @NSManaged public var trackingItem: TrackingItem?
}

// MARK: - Typed Accessors

extension FetchLog {
    var fetchOutcome: FetchOutcome {
        get { FetchOutcome(rawValue: outcome) ?? .failure }
        set { outcome = newValue.rawValue }
    }

    var fetchErrorType: FetchErrorType {
        get { FetchErrorType(rawValue: errorType) ?? .none }
        set { errorType = newValue.rawValue }
    }

    var fetchExtractMethod: ExtractMethod {
        get { ExtractMethod(rawValue: extractMethod) ?? .failed }
        set { extractMethod = newValue.rawValue }
    }

    var isSuccess: Bool { fetchOutcome == .success }
}

// MARK: - FetchRequest

extension FetchLog {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<FetchLog> {
        NSFetchRequest<FetchLog>(entityName: "FetchLog")
    }
}

// MARK: - Convenience Init

extension FetchLog {
    static func create(
        for item: TrackingItem,
        outcome: FetchOutcome,
        httpStatus: Int16? = nil,
        errorType: FetchErrorType = .none,
        extractMethod: ExtractMethod = .failed,
        durationMs: Int32,
        note: String? = nil,
        context: NSManagedObjectContext
    ) -> FetchLog {
        let log = FetchLog(context: context)
        log.id = UUID()
        log.trackingItemId = item.id
        log.timestamp = Date()
        log.fetchOutcome = outcome
        log.httpStatus = httpStatus ?? 0
        log.fetchErrorType = errorType
        log.fetchExtractMethod = extractMethod
        log.durationMs = durationMs
        log.note = note
        log.trackingItem = item
        return log
    }
}
