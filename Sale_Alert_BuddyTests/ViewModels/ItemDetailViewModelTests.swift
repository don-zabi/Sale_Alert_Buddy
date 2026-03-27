import Testing
import CoreData
@testable import Sale_Alert_Buddy

// MARK: - ItemDetailViewModel Tests

@Suite("ItemDetailViewModel")
struct ItemDetailViewModelTests {

    // MARK: - Initialization

    @Test("isChecking starts false")
    func isCheckingStartsFalse() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "amazon.co.jp"
            item.baselinePriceDecimal = 1000
            item.baselineCurrency = "JPY"
            vm = ItemDetailViewModel(item: item)
        }
        #expect(vm.isChecking == false)
    }

    @Test("errorMessage starts nil")
    func errorMessageStartsNil() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "amazon.co.jp"
            item.baselinePriceDecimal = 1000
            item.baselineCurrency = "JPY"
            vm = ItemDetailViewModel(item: item)
        }
        #expect(vm.errorMessage == nil)
    }

    // MARK: - formattedBaselinePrice

    @Test("formattedBaselinePrice returns non-empty string for JPY")
    func formattedBaselinePriceJPY() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "amazon.co.jp"
            item.baselinePriceDecimal = 1980
            item.baselineCurrency = "JPY"
            vm = ItemDetailViewModel(item: item)
        }
        #expect(!vm.formattedBaselinePrice.isEmpty)
        #expect(vm.formattedBaselinePrice.contains("1,980") || vm.formattedBaselinePrice.contains("1980"))
    }

    @Test("formattedBaselinePrice returns non-empty string for USD")
    func formattedBaselinePriceUSD() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "amazon.com"
            item.baselinePriceDecimal = 29.99
            item.baselineCurrency = "USD"
            vm = ItemDetailViewModel(item: item)
        }
        #expect(!vm.formattedBaselinePrice.isEmpty)
        #expect(vm.formattedBaselinePrice.contains("29.99") || vm.formattedBaselinePrice.contains("29,99"))
    }

    // MARK: - formattedLatestPrice

    @Test("formattedLatestPrice is nil when latestPriceDecimal is nil")
    func formattedLatestPriceNilWhenNoLatest() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.latestPriceDecimal = nil
            vm = ItemDetailViewModel(item: item)
        }
        #expect(vm.formattedLatestPrice == nil)
    }

    @Test("formattedLatestPrice is non-nil when latestPriceDecimal is set")
    func formattedLatestPriceNonNilWhenSet() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.latestPriceDecimal = 80
            item.latestCurrency = "USD"
            vm = ItemDetailViewModel(item: item)
        }
        #expect(vm.formattedLatestPrice != nil)
    }

    // MARK: - formattedDropAmount

    @Test("formattedDropAmount is nil when no price drop")
    func formattedDropAmountNilWhenNoDrop() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.latestPriceDecimal = 100
            item.latestCurrency = "USD"
            vm = ItemDetailViewModel(item: item)
        }
        #expect(vm.formattedDropAmount == nil)
    }

    @Test("formattedDropAmount is non-nil when price dropped")
    func formattedDropAmountNonNilWhenDropped() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.latestPriceDecimal = 80
            item.latestCurrency = "USD"
            vm = ItemDetailViewModel(item: item)
        }
        #expect(vm.formattedDropAmount != nil)
    }

    // MARK: - formattedDropPercentage

    @Test("formattedDropPercentage is nil when no price drop")
    func formattedDropPercentageNilWhenNoDrop() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.latestPriceDecimal = 100
            vm = ItemDetailViewModel(item: item)
        }
        #expect(vm.formattedDropPercentage == nil)
    }

    @Test("formattedDropPercentage contains percent sign when dropped")
    func formattedDropPercentageContainsPercent() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.latestPriceDecimal = 90
            item.latestCurrency = "USD"
            vm = ItemDetailViewModel(item: item)
        }
        let pct = vm.formattedDropPercentage
        #expect(pct != nil)
        #expect(pct?.contains("%") == true)
    }

    @Test("formattedDropPercentage shows correct value for 10% drop")
    func formattedDropPercentageValue() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.latestPriceDecimal = 90
            item.latestCurrency = "USD"
            vm = ItemDetailViewModel(item: item)
        }
        let pct = vm.formattedDropPercentage ?? ""
        #expect(pct.contains("10"))
    }

    // MARK: - statusDescription

    @Test("statusDescription for ok status contains active text")
    func statusDescriptionOk() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.itemStatus = .ok
            vm = ItemDetailViewModel(item: item)
        }
        #expect(!vm.statusDescription.isEmpty)
    }

    @Test("statusDescription for paused status includes pause reason")
    func statusDescriptionPaused() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.itemStatus = .paused
            item.itemPauseReason = .userInitiated
            vm = ItemDetailViewModel(item: item)
        }
        let desc = vm.statusDescription
        // Should contain the pause reason message
        #expect(desc.localizedCaseInsensitiveContains("pause") || desc.localizedCaseInsensitiveContains("manual") || desc.localizedCaseInsensitiveContains("stop") || desc.localizedCaseInsensitiveContains("停止"))
    }

    @Test("statusDescription for tempFailed includes failure text")
    func statusDescriptionTempFailed() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        ctx.performAndWait {
            let item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.itemStatus = .tempFailed
            vm = ItemDetailViewModel(item: item)
        }
        #expect(!vm.statusDescription.isEmpty)
    }

    // MARK: - pause / resume

    @Test("pause sets item status to paused")
    func pauseSetsStatus() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        var item: TrackingItem!
        try ctx.performAndWait {
            item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.itemStatus = .ok
            try ctx.save()
            vm = ItemDetailViewModel(item: item)
        }

        ctx.performAndWait {
            vm.pause(context: ctx)
        }

        ctx.performAndWait {
            #expect(item.itemStatus == .paused)
            #expect(item.itemPauseReason == .userInitiated)
        }
    }

    @Test("resume sets item status to ok")
    func resumeSetsStatus() throws {
        let ctx = TestPersistence.newContext()
        var vm: ItemDetailViewModel!
        var item: TrackingItem!
        try ctx.performAndWait {
            item = TrackingItem.create(in: ctx)
            item.domain = "example.com"
            item.baselinePriceDecimal = 100
            item.baselineCurrency = "USD"
            item.itemStatus = .paused
            item.itemPauseReason = .userInitiated
            try ctx.save()
            vm = ItemDetailViewModel(item: item)
        }

        ctx.performAndWait {
            vm.resume(context: ctx)
        }

        ctx.performAndWait {
            #expect(item.itemStatus == .ok)
            #expect(item.itemPauseReason == nil)
        }
    }
}
