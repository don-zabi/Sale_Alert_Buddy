import Testing
import CoreData
@testable import Sale_Alert_Buddy

// MARK: - ItemListViewModel Tests

@Suite("ItemListViewModel")
struct ItemListViewModelTests {

    // MARK: - Initialization

    @Test("Default sort order is createdDesc")
    func defaultSortOrder() {
        let vm = ItemListViewModel()
        #expect(vm.sortOrder == .createdDesc)
    }

    @Test("Default filter status is all")
    func defaultFilterStatus() {
        let vm = ItemListViewModel()
        #expect(vm.filterStatus == .all)
    }

    @Test("showingAddSheet starts false")
    func showingAddSheetStartsFalse() {
        let vm = ItemListViewModel()
        #expect(vm.showingAddSheet == false)
    }

    @Test("errorMessage starts nil")
    func errorMessageStartsNil() {
        let vm = ItemListViewModel()
        #expect(vm.errorMessage == nil)
    }

    // MARK: - isChecking / checkProgress proxy

    @Test("isChecking reflects service state")
    @MainActor
    func isCheckingReflectsService() {
        let service = PriceCheckService()
        let vm = ItemListViewModel(checkService: service)
        #expect(vm.isChecking == service.isChecking)
    }

    @Test("checkProgress reflects service state")
    @MainActor
    func checkProgressReflectsService() {
        let service = PriceCheckService()
        let vm = ItemListViewModel(checkService: service)
        #expect(vm.checkProgress == service.checkProgress)
    }

    // MARK: - SortOrder enum

    @Test("SortOrder cases exist")
    func sortOrderCases() {
        let cases: [ItemListViewModel.SortOrder] = [.createdDesc, .priceDropDesc, .lastCheckedAsc]
        #expect(cases.count == 3)
    }

    // MARK: - FilterStatus enum

    @Test("FilterStatus cases exist")
    func filterStatusCases() {
        let cases: [ItemListViewModel.FilterStatus] = [.all, .activeOnly, .pausedOnly]
        #expect(cases.count == 3)
    }

    // MARK: - deleteItem

    @Test("deleteItem removes item from fetch results")
    func deleteItemRemovesFromContext() throws {
        // Use a fresh isolated store so fetch results are deterministic
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext
        let vm = ItemListViewModel()

        let uniqueURL = "https://example-\(UUID().uuidString).com"

        // Create and save item
        let item = TrackingItem.create(in: ctx)
        item.currentUrl = uniqueURL
        item.domain = "example.com"
        store.save(context: ctx)

        // Confirm item exists
        let request = TrackingItem.fetchRequest()
        request.predicate = NSPredicate(format: "currentUrl == %@", uniqueURL)
        let before = (try? ctx.fetch(request)) ?? []
        #expect(before.count == 1)

        // Delete the item
        vm.deleteItem(item, context: ctx)

        // Fetch again — item should be gone
        ctx.processPendingChanges()
        let after = (try? ctx.fetch(request)) ?? []
        #expect(after.isEmpty)
    }

    // MARK: - pauseItem / resumeItem

    @Test("pauseItem sets status to paused and pauseReason to userInitiated")
    func pauseItemSetsStatus() throws {
        let ctx = TestPersistence.newContext()
        let vm = ItemListViewModel()

        var item: TrackingItem!
        try ctx.performAndWait {
            item = TrackingItem.create(in: ctx)
            item.itemStatus = .ok
            try ctx.save()
        }

        ctx.performAndWait {
            vm.pauseItem(item, context: ctx)
        }

        ctx.performAndWait {
            #expect(item.itemStatus == .paused)
            #expect(item.itemPauseReason == .userInitiated)
        }
    }

    @Test("resumeItem sets status to ok and clears pauseReason")
    func resumeItemSetsStatus() throws {
        let ctx = TestPersistence.newContext()
        let vm = ItemListViewModel()

        var item: TrackingItem!
        try ctx.performAndWait {
            item = TrackingItem.create(in: ctx)
            item.itemStatus = .paused
            item.itemPauseReason = .userInitiated
            try ctx.save()
        }

        ctx.performAndWait {
            vm.resumeItem(item, context: ctx)
        }

        ctx.performAndWait {
            #expect(item.itemStatus == .ok)
            #expect(item.itemPauseReason == nil)
        }
    }

    @Test("resumeItem clears consecutive failure count")
    func resumeItemClearsFailCount() throws {
        let ctx = TestPersistence.newContext()
        let vm = ItemListViewModel()

        var item: TrackingItem!
        try ctx.performAndWait {
            item = TrackingItem.create(in: ctx)
            item.itemStatus = .paused
            item.itemPauseReason = .consecutiveFailures
            item.failCountConsecutive = 5
            try ctx.save()
        }

        ctx.performAndWait {
            vm.resumeItem(item, context: ctx)
        }

        ctx.performAndWait {
            #expect(item.failCountConsecutive == 0)
        }
    }

    // MARK: - showingAddSheet mutation

    @Test("showingAddSheet can be set to true")
    func showingAddSheetMutation() {
        let vm = ItemListViewModel()
        vm.showingAddSheet = true
        #expect(vm.showingAddSheet == true)
    }
}
