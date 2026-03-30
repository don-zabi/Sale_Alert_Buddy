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
    var selectedCategory: String? = nil

    // MARK: - Sheet / Error State

    var showingAddSheet: Bool = false
    var errorMessage: String?

    // MARK: - Category Management State

    var showingCategoryAdd: Bool = false
    var showingCategoryEdit: Bool = false
    var categoryEditTarget: String? = nil
    var categoryNameInput: String = ""
    var showingCategoryDeleteConfirm: Bool = false
    var categoryDeleteTarget: String? = nil

    /// User-created categories not yet tied to any item, persisted in UserDefaults.
    var standaloneCategories: [String] = {
        UserDefaults.standard.stringArray(forKey: "standaloneCategories") ?? []
    }()

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

    func shouldOfferManualCheck(for item: TrackingItem) -> Bool {
        if item.itemLastErrorType != .none {
            return true
        }

        if item.itemStatus == .tempFailed {
            return true
        }

        return item.itemStatus == .paused && item.itemPauseReason == .consecutiveFailures
    }

    func handleManualCapture(
        for item: TrackingItem,
        capturedPage: InAppCapturedPage,
        context: NSManagedObjectContext
    ) async -> InAppPriceCaptureResponse {
        do {
            let result = try await checkService.checkItemUsingLoadedPage(
                item,
                pageHTML: capturedPage.html,
                pageURL: capturedPage.url,
                context: context,
                visiblePriceResult: capturedPage.visiblePriceResult
            )
            let priceText = NotificationService.formatPrice(
                result.priceResult.price,
                currency: result.priceResult.currency
            )
            return InAppPriceCaptureResponse(
                shouldDismiss: true,
                message: String(
                    format: String(
                        localized: "manualCapture.success",
                        defaultValue: "価格を更新しました: %@"
                    ),
                    priceText
                )
            )
        } catch let checkError as PriceCheckError {
            return InAppPriceCaptureResponse(
                shouldDismiss: false,
                message: checkError.errorDescription ?? ""
            )
        } catch {
            return InAppPriceCaptureResponse(
                shouldDismiss: false,
                message: error.localizedDescription
            )
        }
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

    // MARK: - Category Helpers

    /// Returns all categories sorted by usage count (most-used first), then alphabetically.
    ///
    /// Merges item-assigned categories with standalone categories that haven't been
    /// assigned to any item yet.
    func sortedCategories(from items: [TrackingItem]) -> [String] {
        var counts: [String: Int] = [:]
        for item in items {
            if let cat = item.itemCategory { counts[cat, default: 0] += 1 }
        }
        for cat in standaloneCategories where counts[cat] == nil {
            counts[cat] = 0
        }
        return counts.keys.sorted {
            let a = counts[$0, default: 0], b = counts[$1, default: 0]
            return a != b ? a > b : $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    // MARK: - Category Add

    func startAddingCategory() {
        categoryNameInput = ""
        showingCategoryAdd = true
    }

    func confirmAddCategory() {
        let trimmed = categoryNameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !standaloneCategories.contains(trimmed) {
            standaloneCategories.append(trimmed)
            UserDefaults.standard.set(standaloneCategories, forKey: "standaloneCategories")
        }
        showingCategoryAdd = false
        categoryNameInput = ""
    }

    // MARK: - Category Edit

    func startEditingCategory(_ name: String) {
        categoryEditTarget = name
        categoryNameInput = name
        showingCategoryEdit = true
    }

    func confirmRenameCategory(items: [TrackingItem], context: NSManagedObjectContext) {
        guard let oldName = categoryEditTarget else { return }
        let trimmed = categoryNameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != oldName else {
            cancelCategoryAction()
            return
        }
        for item in items where item.itemCategory == oldName {
            item.itemCategory = trimmed
        }
        PersistenceController.shared.save(context: context)
        if let idx = standaloneCategories.firstIndex(of: oldName) {
            standaloneCategories[idx] = trimmed
            UserDefaults.standard.set(standaloneCategories, forKey: "standaloneCategories")
        }
        if selectedCategory == oldName { selectedCategory = trimmed }
        showingCategoryEdit = false
        categoryEditTarget = nil
        categoryNameInput = ""
    }

    // MARK: - Category Delete

    func startDeletingCategory(_ name: String) {
        categoryDeleteTarget = name
        showingCategoryDeleteConfirm = true
    }

    func confirmDeleteCategory(items: [TrackingItem], context: NSManagedObjectContext) {
        guard let name = categoryDeleteTarget else { return }
        for item in items where item.itemCategory == name {
            item.itemCategory = nil
        }
        PersistenceController.shared.save(context: context)
        standaloneCategories.removeAll { $0 == name }
        UserDefaults.standard.set(standaloneCategories, forKey: "standaloneCategories")
        if selectedCategory == name { selectedCategory = nil }
        categoryDeleteTarget = nil
        showingCategoryDeleteConfirm = false
    }

    func cancelCategoryAction() {
        showingCategoryAdd = false
        showingCategoryEdit = false
        categoryEditTarget = nil
        categoryNameInput = ""
    }
}
