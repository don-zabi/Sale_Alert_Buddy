import Foundation
import CoreData
import UIKit
import Observation

struct PriceTrendPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let price: Double
}

/// ViewModel for the item detail screen.
///
/// Provides formatted price strings, status descriptions, and delegates
/// check/pause/resume operations.
@Observable
final class ItemDetailViewModel {

    // MARK: - State

    let item: TrackingItem
    var isChecking: Bool = false
    var errorMessage: String?

    // MARK: - Category Editing State

    var showingCategoryEdit: Bool = false
    var categoryNameInput: String = ""
    var showingMemoEdit: Bool = false
    var memoInput: String = ""

    // MARK: - Init

    init(item: TrackingItem) {
        self.item = item
    }

    // MARK: - Formatted Price Strings

    /// Baseline (registered) price formatted with currency symbol.
    var formattedBaselinePrice: String {
        NotificationService.formatPrice(item.baselinePriceDecimal, currency: item.baselineCurrency)
    }

    /// Latest checked price formatted with currency symbol, or nil if not yet checked.
    var formattedLatestPrice: String? {
        guard let latest = item.latestPriceDecimal,
              let currency = item.latestCurrency else { return nil }
        return NotificationService.formatPrice(latest, currency: currency)
    }

    /// Formatted drop amount (baseline minus latest), or nil if no drop.
    var formattedDropAmount: String? {
        guard let drop = item.dropAmount else { return nil }
        let currency = item.latestCurrency ?? item.baselineCurrency
        return "-" + NotificationService.formatPrice(drop, currency: currency)
    }

    /// Drop percentage formatted as "10.2%", or nil if no drop.
    var formattedDropPercentage: String? {
        guard let pct = item.dropPercentage else { return nil }
        return String(format: "%.1f%%", pct)
    }

    var notificationConditionType: NotificationConditionType {
        item.itemNotificationConditionType
    }

    var notificationConditionValueText: String {
        let value = item.itemNotificationConditionValue
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    var notificationConditionDescription: String {
        let value = item.itemNotificationConditionValue
        switch item.itemNotificationConditionType {
        case .percentage:
            let text = value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
            return String(
                format: String(localized: "detail.notifyThreshold.percent", defaultValue: "Notify when drop is %@%% or more"),
                text
            )
        case .amount:
            let formatted = NotificationService.formatPrice(Decimal(value), currency: item.baselineCurrency)
            return String(
                format: String(localized: "detail.notifyThreshold.amount", defaultValue: "Notify when drop amount is %@ or more"),
                formatted
            )
        case .targetPrice:
            let formatted = NotificationService.formatPrice(Decimal(value), currency: item.baselineCurrency)
            return String(
                format: String(localized: "detail.notifyThreshold.target", defaultValue: "Notify when price is %@ or below"),
                formatted
            )
        }
    }

    /// Calculated notification price based on the *saved* condition and the current latest price.
    ///
    /// Returns nil for targetPrice type (user specifies directly), when no current price is
    /// available, or when the result would be zero/negative.
    var savedNotificationTargetPrice: String? {
        let type = item.itemNotificationConditionType
        guard type != .targetPrice else { return nil }
        let value = item.itemNotificationConditionValue
        guard value > 0 else { return nil }

        let currentPrice = NSDecimalNumber(
            decimal: item.latestPriceDecimal ?? item.baselinePriceDecimal
        ).doubleValue
        let currency = item.latestCurrency ?? item.baselineCurrency

        let target: Double
        switch type {
        case .percentage: target = currentPrice * (1.0 - value / 100.0)
        case .amount:     target = currentPrice - value
        case .targetPrice: return nil
        }

        guard target > 0 else { return nil }
        return NotificationService.formatPrice(
            NSDecimalNumber(value: target.rounded()).decimalValue,
            currency: currency
        )
    }

    // MARK: - Editing Preview

    struct NotificationPreview {
        /// Human-readable description of the rule being edited.
        let description: String
        /// Calculated price at which the notification would fire, or nil when not applicable.
        let targetPrice: String?
    }

    /// Real-time preview computed from the values currently shown in the UI (not yet saved).
    ///
    /// Returns nil when the valueText is empty or invalid.
    func editingPreview(type: NotificationConditionType, valueText: String) -> NotificationPreview? {
        let normalized = valueText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }

        // Description
        let description: String
        switch type {
        case .percentage:
            let text = value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
            description = String(
                format: String(localized: "detail.notifyThreshold.percent",
                               defaultValue: "Notify when drop is %@%% or more"),
                text
            )
        case .amount:
            let formatted = NotificationService.formatPrice(
                NSDecimalNumber(value: value).decimalValue,
                currency: item.baselineCurrency
            )
            description = String(
                format: String(localized: "detail.notifyThreshold.amount",
                               defaultValue: "Notify when drop amount is %@ or more"),
                formatted
            )
        case .targetPrice:
            let formatted = NotificationService.formatPrice(
                NSDecimalNumber(value: value).decimalValue,
                currency: item.baselineCurrency
            )
            description = String(
                format: String(localized: "detail.notifyThreshold.target",
                               defaultValue: "Notify when price is %@ or below"),
                formatted
            )
        }

        // Calculated target price (only for percentage / amount types)
        var targetPrice: String?
        if type != .targetPrice {
            let currentPrice = NSDecimalNumber(
                decimal: item.latestPriceDecimal ?? item.baselinePriceDecimal
            ).doubleValue
            let currency = item.latestCurrency ?? item.baselineCurrency

            let target: Double
            switch type {
            case .percentage: target = currentPrice * (1.0 - value / 100.0)
            case .amount:     target = currentPrice - value
            case .targetPrice: target = 0
            }

            if target > 0 {
                targetPrice = NotificationService.formatPrice(
                    NSDecimalNumber(value: target.rounded()).decimalValue,
                    currency: currency
                )
            }
        }

        return NotificationPreview(description: description, targetPrice: targetPrice)
    }

    var priceTrendPoints: [PriceTrendPoint] {
        var points: [PriceTrendPoint] = [
            PriceTrendPoint(
                timestamp: item.createdAt,
                price: NSDecimalNumber(decimal: item.baselinePriceDecimal).doubleValue
            )
        ]

        let successLogs = item.fetchLogsArray
            .filter(\.isSuccess)
            .sorted { $0.timestamp < $1.timestamp }

        for log in successLogs {
            guard let parsed = FetchLog.parsePriceNote(log.note),
                  parsed.currency == item.baselineCurrency else {
                continue
            }
            points.append(
                PriceTrendPoint(
                    timestamp: log.timestamp,
                    price: NSDecimalNumber(decimal: parsed.price).doubleValue
                )
            )
        }

        if points.count == 1,
           let latest = item.latestPriceDecimal,
           item.latestCurrency == item.baselineCurrency,
           let lastSuccess = item.lastSuccessAt,
           lastSuccess > item.createdAt {
            points.append(
                PriceTrendPoint(
                    timestamp: lastSuccess,
                    price: NSDecimalNumber(decimal: latest).doubleValue
                )
            )
        }

        return points.sorted { $0.timestamp < $1.timestamp }
    }

    /// Dynamic Y-axis domain for the price trend chart.
    ///
    /// Pads around the actual price range so even small drops (e.g. ¥2,000 on ¥85,000)
    /// occupy a meaningful portion of the chart height.
    var chartYDomain: ClosedRange<Double> {
        let prices = priceTrendPoints.map(\.price)
        guard let minP = prices.min(), let maxP = prices.max() else { return 0...1 }
        let range = maxP - minP
        // padding = at least 40% of the change, or at least 1% of the max price
        let padding = max(range * 0.4, maxP * 0.01)
        let yMin = max(0, minP - padding)
        let yMax = maxP + padding
        return yMin...yMax
    }

    // MARK: - Status Description

    /// Human-readable description of the item's current status.
    ///
    /// For paused items, appends the pause reason so the user understands why.
    var statusDescription: String {
        switch item.itemStatus {
        case .ok:
            return item.itemStatus.displayName
        case .tempFailed:
            let errorName = item.itemLastErrorType.displayName
            if errorName.isEmpty {
                return item.itemStatus.displayName
            }
            return "\(item.itemStatus.displayName) — \(errorName)"
        case .paused:
            if let reason = item.itemPauseReason {
                return "\(item.itemStatus.displayName): \(reason.displayMessage)"
            }
            return item.itemStatus.displayName
        }
    }

    // MARK: - Actions

    /// Fetches the latest price for this item.
    func checkNow(context: NSManagedObjectContext) async {
        isChecking = true
        errorMessage = nil
        await PriceCheckService.shared.checkItem(item, context: context)
        isChecking = false
    }

    /// Pauses monitoring for this item (user-initiated).
    func pause(context: NSManagedObjectContext) {
        item.itemStatus = .paused
        item.itemPauseReason = .userInitiated
        PersistenceController.shared.save(context: context)
    }

    /// Resumes monitoring for this item and clears the consecutive failure count.
    func resume(context: NSManagedObjectContext) {
        item.itemStatus = .ok
        item.itemPauseReason = nil
        item.failCountConsecutive = 0
        PersistenceController.shared.save(context: context)
    }

    /// Deletes this item from Core Data and saves. The NavigationStack will pop automatically
    /// because the item is removed from the fetch results the list view observes.
    func deleteItem(context: NSManagedObjectContext) {
        context.delete(item)
        PersistenceController.shared.save(context: context)
    }

    func updateNotificationCondition(
        type: NotificationConditionType,
        valueText: String,
        context: NSManagedObjectContext
    ) {
        let normalized = valueText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard let value = Double(normalized), value > 0 else {
            errorMessage = String(
                localized: "detail.notifyThreshold.invalidValue",
                defaultValue: "Enter a valid number greater than 0."
            )
            return
        }

        item.itemNotificationConditionType = type
        item.itemNotificationConditionValue = value

        if type == .percentage {
            item.notificationThreshold = value / 100
        }

        PersistenceController.shared.save(context: context)
    }

    /// Opens the product page in Safari.
    func openInSafari() {
        guard let url = URL(string: item.currentUrl) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Category Actions

    func startEditingCategory() {
        categoryNameInput = item.itemCategory ?? ""
        showingCategoryEdit = true
    }

    func saveCategoryEdit(context: NSManagedObjectContext) {
        let trimmed = categoryNameInput.trimmingCharacters(in: .whitespaces)
        item.itemCategory = trimmed.isEmpty ? nil : trimmed
        PersistenceController.shared.save(context: context)
        showingCategoryEdit = false
        categoryNameInput = ""
    }

    func setCategory(_ name: String, context: NSManagedObjectContext) {
        item.itemCategory = name
        PersistenceController.shared.save(context: context)
    }

    func clearCategory(context: NSManagedObjectContext) {
        item.itemCategory = nil
        PersistenceController.shared.save(context: context)
    }

    // MARK: - Memo Actions

    func startEditingMemo() {
        memoInput = item.memo ?? ""
        showingMemoEdit = true
    }

    func saveMemoEdit(context: NSManagedObjectContext) {
        let trimmed = memoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        item.memo = trimmed.isEmpty ? nil : trimmed
        PersistenceController.shared.save(context: context)
        showingMemoEdit = false
        memoInput = ""
    }

    func clearMemo(context: NSManagedObjectContext) {
        item.memo = nil
        PersistenceController.shared.save(context: context)
    }
}
