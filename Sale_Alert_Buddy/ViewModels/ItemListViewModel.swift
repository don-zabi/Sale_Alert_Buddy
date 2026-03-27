import Foundation
import CoreData
import Observation

/// ViewModel for the main item list screen.
///
/// Manages sort/filter state, the add-item sheet flag, and delegates checking
/// operations to `PriceCheckService`. Because `PriceCheckService` is `@Observable`,
/// changes to `isChecking` and `checkProgress` flow through automatically.
@Observable
final class ItemListViewModel {

    // MARK: - Sort / Filter

    enum SortOrder {
        case createdDesc
        case priceDropDesc
        case lastCheckedAsc
    }

    enum FilterStatus {
        case all
        case activeOnly
        case pausedOnly
    }

    var sortOrder: SortOrder = .createdDesc
    var filterStatus: FilterStatus = .all

    // MARK: - Sheet / Error State

    var showingAddSheet: Bool = false
    var errorMessage: String?

    // MARK: - Service

    var checkService: PriceCheckService

    init(checkService: PriceCheckService = .shared) {
        self.checkService = checkService
    }

    // MARK: - Computed Proxies

    var isChecking: Bool { checkService.isChecking }
    var checkProgress: Double { checkService.checkProgress }

    // MARK: - Actions

    /// Triggers a price check for all active items.
    func checkAll(context: NSManagedObjectContext) async {
        await checkService.checkAll(context: context)
    }

    /// Deletes an item from Core Data and saves.
    func deleteItem(_ item: TrackingItem, context: NSManagedObjectContext) {
        context.delete(item)
        PersistenceController.shared.save(context: context)
    }

    /// Pauses monitoring for an item (user-initiated).
    func pauseItem(_ item: TrackingItem, context: NSManagedObjectContext) {
        item.itemStatus = .paused
        item.itemPauseReason = .userInitiated
        PersistenceController.shared.save(context: context)
    }

    /// Resumes monitoring for a previously-paused item.
    ///
    /// Clears the consecutive failure count so the item gets a clean slate.
    func resumeItem(_ item: TrackingItem, context: NSManagedObjectContext) {
        item.itemStatus = .ok
        item.itemPauseReason = nil
        item.failCountConsecutive = 0
        PersistenceController.shared.save(context: context)
    }
}
