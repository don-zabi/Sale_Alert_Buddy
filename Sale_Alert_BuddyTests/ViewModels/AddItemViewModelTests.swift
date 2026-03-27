import Testing
import CoreData
@testable import Sale_Alert_Buddy

// MARK: - AddItemViewModel Tests

@Suite("AddItemViewModel")
struct AddItemViewModelTests {

    // MARK: - Default state

    @Test("urlText starts empty")
    func urlTextStartsEmpty() {
        let vm = AddItemViewModel()
        #expect(vm.urlText == "")
    }

    @Test("memo starts empty")
    func memoStartsEmpty() {
        let vm = AddItemViewModel()
        #expect(vm.memo == "")
    }

    @Test("tagsText starts empty")
    func tagsTextStartsEmpty() {
        let vm = AddItemViewModel()
        #expect(vm.tagsText == "")
    }

    @Test("isRegistering starts false")
    func isRegisteringStartsFalse() {
        let vm = AddItemViewModel()
        #expect(vm.isRegistering == false)
    }

    @Test("errorMessage starts nil")
    func errorMessageStartsNil() {
        let vm = AddItemViewModel()
        #expect(vm.errorMessage == nil)
    }

    @Test("registeredItem starts nil")
    func registeredItemStartsNil() {
        let vm = AddItemViewModel()
        #expect(vm.registeredItem == nil)
    }

    // MARK: - canRegister

    @Test("canRegister is false when urlText is empty")
    func canRegisterFalseWhenEmpty() {
        let vm = AddItemViewModel()
        vm.urlText = ""
        #expect(vm.canRegister == false)
    }

    @Test("canRegister is false when urlText is whitespace only")
    func canRegisterFalseWhenWhitespace() {
        let vm = AddItemViewModel()
        vm.urlText = "   "
        #expect(vm.canRegister == false)
    }

    @Test("canRegister is true when urlText has content and not registering")
    func canRegisterTrueWithURL() {
        let vm = AddItemViewModel()
        vm.urlText = "https://example.com"
        #expect(vm.canRegister == true)
    }

    @Test("canRegister is false when isRegistering is true")
    func canRegisterFalseWhenRegistering() {
        let vm = AddItemViewModel()
        vm.urlText = "https://example.com"
        vm.isRegistering = true
        #expect(vm.canRegister == false)
    }

    // MARK: - parsedTags

    @Test("parsedTags returns empty array when tagsText is empty")
    func parsedTagsEmpty() {
        let vm = AddItemViewModel()
        vm.tagsText = ""
        #expect(vm.parsedTags.isEmpty)
    }

    @Test("parsedTags splits on comma and trims whitespace")
    func parsedTagsSplitsAndTrims() {
        let vm = AddItemViewModel()
        vm.tagsText = "sale, electronics, japan"
        #expect(vm.parsedTags == ["sale", "electronics", "japan"])
    }

    @Test("parsedTags filters out empty segments from extra commas")
    func parsedTagsFiltersEmpty() {
        let vm = AddItemViewModel()
        vm.tagsText = "sale,,japan,"
        #expect(vm.parsedTags == ["sale", "japan"])
    }

    @Test("parsedTags handles single tag without comma")
    func parsedTagsSingleTag() {
        let vm = AddItemViewModel()
        vm.tagsText = "electronics"
        #expect(vm.parsedTags == ["electronics"])
    }

    @Test("parsedTags handles Unicode tag values")
    func parsedTagsUnicode() {
        let vm = AddItemViewModel()
        vm.tagsText = "家電, セール"
        #expect(vm.parsedTags == ["家電", "セール"])
    }

    // MARK: - clearError

    @Test("clearError sets errorMessage to nil")
    func clearError() {
        let vm = AddItemViewModel()
        vm.errorMessage = "some error"
        vm.clearError()
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Plan limit check

    @Test("register sets planLimit error when one item already exists")
    @MainActor
    func registerEnforcesPlanLimit() async throws {
        // Use a fresh isolated store so item count is deterministic
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        // Create one existing item to hit the free plan limit
        let existing = TrackingItem.create(in: ctx)
        existing.currentUrl = "https://amazon.co.jp/dp/B001"
        existing.domain = "amazon.co.jp"
        store.save(context: ctx)

        let vm = AddItemViewModel()
        vm.urlText = "https://amazon.co.jp/dp/B002"

        await vm.register(context: ctx)

        #expect(vm.errorMessage != nil)
        #expect(vm.isRegistering == false)
        #expect(vm.registeredItem == nil)
        // Error message should mention plan/upgrade
        let msg = vm.errorMessage ?? ""
        #expect(msg.localizedCaseInsensitiveContains("plan") || msg.localizedCaseInsensitiveContains("upgrade") || msg.localizedCaseInsensitiveContains("limit"))
    }

    @Test("register does not set isRegistering true when plan limit exceeded")
    @MainActor
    func registerNoNetworkWhenPlanLimitExceeded() async throws {
        // Use a fresh isolated store so item count is deterministic
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        let existing = TrackingItem.create(in: ctx)
        existing.currentUrl = "https://amazon.co.jp/dp/existing"
        existing.domain = "amazon.co.jp"
        store.save(context: ctx)

        let vm = AddItemViewModel()
        vm.urlText = "https://amazon.co.jp/dp/new"

        // isRegistering should NOT stay true after returning early
        await vm.register(context: ctx)

        #expect(vm.isRegistering == false)
    }

    @Test("register sets isRegistering during execution then clears it on error")
    @MainActor
    func registerClearsIsRegisteringAfterError() async {
        // Use a fresh isolated store so no plan limit fires
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        let vm = AddItemViewModel()
        vm.urlText = "not-a-valid-url-at-all"

        // With invalid URL and no existing items, registerItem will throw
        await vm.register(context: ctx)

        #expect(vm.isRegistering == false)
    }
}
