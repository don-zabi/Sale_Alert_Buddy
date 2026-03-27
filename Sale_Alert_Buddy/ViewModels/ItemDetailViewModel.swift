import Foundation
import CoreData
import UIKit
import Observation

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

    /// Opens the product page in Safari.
    func openInSafari() {
        guard let url = URL(string: item.currentUrl) else { return }
        UIApplication.shared.open(url)
    }
}
