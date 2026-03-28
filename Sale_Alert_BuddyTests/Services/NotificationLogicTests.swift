import Testing
import Foundation
import CoreData
@testable import Sale_Alert_Buddy

/// Tests the `shouldNotify` business logic in NotificationService.
///
/// Core conditions are verified:
/// 1. newPrice < baselinePrice
/// 2. newPrice < lastNotifiedPrice (or lastNotifiedPrice is nil)
/// 3. currency == baselineCurrency
/// 4. per-item notification condition is satisfied
///
/// Tests use an in-memory Core Data store so no disk state persists between runs.
@MainActor
struct NotificationLogicTests {

    // MARK: - Helpers

    /// Returns a fresh background context on the shared in-memory store.
    private func makeContext() -> NSManagedObjectContext {
        TestPersistence.newContext()
    }

    /// Creates a TrackingItem suitable for notification tests.
    ///
    /// Defaults:
    /// - baseline: 1000 JPY
    /// - threshold: 0.01 (1%)
    /// - lastNotifiedPrice: nil
    private func makeItem(
        context: NSManagedObjectContext,
        baselinePrice: Decimal = 1000,
        baselineCurrency: String = "JPY",
        notificationThreshold: Double = 0.01,
        lastNotifiedPrice: Decimal? = nil
    ) -> TrackingItem {
        let item = TrackingItem.create(in: context)
        item.baselinePriceDecimal = baselinePrice
        item.baselineCurrency = baselineCurrency
        item.notificationThreshold = notificationThreshold
        item.itemNotificationConditionType = .percentage
        item.itemNotificationConditionValue = notificationThreshold * 100
        item.lastNotifiedPriceDecimal = lastNotifiedPrice
        return item
    }

    // MARK: - Happy Path

    @Test func allConditionsMetReturnsTrue() {
        let context = makeContext()
        let item = makeItem(context: context)

        // 900 < 1000 (baseline), no prior notification, same currency, 10% drop >= 1% threshold
        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 900, currency: "JPY")
        #expect(result == true)
    }

    @Test func exactlyAtThresholdReturnsTrue() {
        let context = makeContext()
        // 1% threshold, 10 JPY drop on 1000 JPY = exactly 1%
        let item = makeItem(context: context, notificationThreshold: 0.01)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 990, currency: "JPY")
        #expect(result == true)
    }

    @Test func firstNotificationEverWithNilLastNotifiedReturnsTrue() {
        let context = makeContext()
        // lastNotifiedPrice is nil — the item has never triggered a notification
        let item = makeItem(context: context, lastNotifiedPrice: nil)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 900, currency: "JPY")
        #expect(result == true)
    }

    // MARK: - Condition 1: newPrice must be below baseline

    @Test func priceEqualToBaselineReturnsFalse() {
        let context = makeContext()
        let item = makeItem(context: context)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 1000, currency: "JPY")
        #expect(result == false)
    }

    @Test func priceAboveBaselineReturnsFalse() {
        let context = makeContext()
        let item = makeItem(context: context)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 1100, currency: "JPY")
        #expect(result == false)
    }

    // MARK: - Condition 2: newPrice must be strictly less than lastNotifiedPrice

    @Test func newPriceEqualToLastNotifiedReturnsFalse() {
        // CRITICAL: must be strictly less than, not merely different
        let context = makeContext()
        let item = makeItem(context: context, lastNotifiedPrice: 900)

        // Price went back up to exactly the last-notified level
        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 900, currency: "JPY")
        #expect(result == false)
    }

    @Test func newPriceAboveLastNotifiedReturnsFalse() {
        let context = makeContext()
        // Price bounced back up from last notified level
        let item = makeItem(context: context, lastNotifiedPrice: 900)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 950, currency: "JPY")
        #expect(result == false)
    }

    @Test func newPriceBelowLastNotifiedReturnsTrue() {
        let context = makeContext()
        // Dropped further from 900 to 850 — new low, should notify
        let item = makeItem(context: context, lastNotifiedPrice: 900)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 850, currency: "JPY")
        #expect(result == true)
    }

    @Test func newPriceStrictlyLessThanLastNotifiedSatisfiesCondition2() {
        let context = makeContext()
        // lastNotified = 901, newPrice = 900 — strictly less, all conditions should pass
        let item = makeItem(context: context, lastNotifiedPrice: 901)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 900, currency: "JPY")
        #expect(result == true)
    }

    // MARK: - Condition 3: currency must match baseline

    @Test func currencyMismatchReturnsFalse() {
        let context = makeContext()
        let item = makeItem(context: context, baselineCurrency: "JPY")

        // Price dropped but in USD, not JPY
        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 900, currency: "USD")
        #expect(result == false)
    }

    @Test func emptyCurrencyReturnsFalse() {
        let context = makeContext()
        let item = makeItem(context: context)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 900, currency: "")
        #expect(result == false)
    }

    // MARK: - Condition 4: percentage drop must meet threshold

    @Test func dropBelowThresholdReturnsFalse() {
        let context = makeContext()
        // 0.5% drop on 1000 JPY = 5 JPY, but threshold is 1%
        let item = makeItem(context: context, notificationThreshold: 0.01)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 995, currency: "JPY")
        #expect(result == false)
    }

    @Test func verySmallDropBelowThresholdReturnsFalse() {
        let context = makeContext()
        // 0.005 drop (0.5%) with 0.01 threshold (1%)
        let item = makeItem(context: context, baselinePrice: 1000, notificationThreshold: 0.01)

        // 1 JPY drop = 0.1% drop, well below 1% threshold
        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 999, currency: "JPY")
        #expect(result == false)
    }

    @Test func dropJustAboveThresholdReturnsTrue() {
        let context = makeContext()
        // 1.1% drop with 1% threshold
        let item = makeItem(context: context, baselinePrice: 1000, notificationThreshold: 0.01)

        // 11 JPY drop = 1.1% >= 1%
        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 989, currency: "JPY")
        #expect(result == true)
    }

    @Test func zeroThresholdFallsBackToDefaultCondition() {
        let context = makeContext()
        // 0.0 is treated as invalid and falls back to default 1% condition.
        let item = makeItem(context: context, notificationThreshold: 0.0)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 995, currency: "JPY")
        #expect(result == false)
    }

    @Test func amountConditionUsesDropAmount() {
        let context = makeContext()
        let item = makeItem(context: context, baselinePrice: 1000)
        item.itemNotificationConditionType = .amount
        item.itemNotificationConditionValue = 200

        #expect(NotificationService.shared.shouldNotify(item: item, newPrice: 850, currency: "JPY") == false)
        #expect(NotificationService.shared.shouldNotify(item: item, newPrice: 800, currency: "JPY") == true)
    }

    @Test func targetPriceConditionUsesAbsolutePrice() {
        let context = makeContext()
        let item = makeItem(context: context, baselinePrice: 1000)
        item.itemNotificationConditionType = .targetPrice
        item.itemNotificationConditionValue = 900

        #expect(NotificationService.shared.shouldNotify(item: item, newPrice: 901, currency: "JPY") == false)
        #expect(NotificationService.shared.shouldNotify(item: item, newPrice: 900, currency: "JPY") == true)
    }

    // MARK: - Guard Clauses

    @Test func zeroPriceReturnsFalse() {
        let context = makeContext()
        let item = makeItem(context: context)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 0, currency: "JPY")
        #expect(result == false)
    }

    @Test func negativePriceReturnsFalse() {
        let context = makeContext()
        let item = makeItem(context: context)

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: -100, currency: "JPY")
        #expect(result == false)
    }

    // MARK: - USD / Multi-currency

    @Test func usdAllConditionsMetReturnsTrue() {
        let context = makeContext()
        let item = makeItem(context: context, baselinePrice: 100, baselineCurrency: "USD", notificationThreshold: 0.10)

        // $85 from $100 = 15% drop >= 10% threshold
        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 85, currency: "USD")
        #expect(result == true)
    }

    @Test func usdCurrencyMismatchReturnsFalse() {
        let context = makeContext()
        let item = makeItem(context: context, baselinePrice: 100, baselineCurrency: "USD")

        let result = NotificationService.shared.shouldNotify(item: item, newPrice: 85, currency: "EUR")
        #expect(result == false)
    }

    // MARK: - formatPrice

    @Test func formatJPY() {
        let formatted = NotificationService.formatPrice(Decimal(1980), currency: "JPY")
        #expect(formatted.contains("1,980") || formatted.contains("1980"))
        #expect(formatted.contains("¥") || formatted.contains("￥"))
    }

    @Test func formatUSD() {
        let formatted = NotificationService.formatPrice(Decimal(string: "19.99")!, currency: "USD")
        #expect(formatted.contains("19.99"))
        #expect(formatted.contains("$"))
    }

    @Test func formatPriceWithUnknownCurrencyFallsBackGracefully() {
        let formatted = NotificationService.formatPrice(Decimal(100), currency: "XYZ")
        // Should not crash; just returns something sensible
        #expect(!formatted.isEmpty)
    }
}
