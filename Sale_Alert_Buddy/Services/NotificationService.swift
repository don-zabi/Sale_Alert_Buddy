import Foundation
import UserNotifications

/// Manages price-drop push notifications.
///
/// All methods are `@MainActor` because `UNUserNotificationCenter` callbacks
/// are typically handled on the main thread and `@Observable` observation is
/// main-thread-bound.
@MainActor
final class NotificationService {

    // MARK: - Shared Instance

    static let shared = NotificationService()

    // MARK: - Init

    private init() {}

    // MARK: - Permission

    /// Requests notification permission from the user.
    ///
    /// - Returns: `true` if permission was granted, `false` otherwise.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    // MARK: - Notification Logic

    /// Determines whether a price-drop notification should be sent for `item`.
    ///
    /// All four conditions must be satisfied:
    /// 1. `newPrice` is strictly less than the baseline price.
    /// 2. `newPrice` is strictly less than the last notified price (or none has been sent yet).
    /// 3. The currency matches the baseline currency.
    /// 4. The percentage drop meets or exceeds `notificationThreshold`.
    ///
    /// Also returns `false` if `newPrice <= 0` or `currency` is empty.
    func shouldNotify(item: TrackingItem, newPrice: Decimal, currency: String) -> Bool {
        // Guard: price must be positive
        guard newPrice > 0 else { return false }
        // Guard: currency must not be empty
        guard !currency.isEmpty else { return false }

        let baseline = item.baselinePriceDecimal

        // Condition 1: new price must be below baseline
        guard newPrice < baseline else { return false }

        // Condition 2: new price must be strictly less than last notified price
        if let lastNotified = item.lastNotifiedPriceDecimal {
            guard newPrice < lastNotified else { return false }
        }

        // Condition 3: currency must match baseline
        guard currency == item.baselineCurrency else { return false }

        // Condition 4: percentage drop must meet threshold
        guard baseline > 0 else { return false }
        let dropFraction = (baseline - newPrice) / baseline
        let threshold = Decimal(item.notificationThreshold)
        guard dropFraction >= threshold else { return false }

        return true
    }

    /// Sends a local price-drop notification for `item`.
    ///
    /// Updates `item.lastNotifiedPriceDecimal` if the notification is scheduled
    /// successfully. The item's context must be saved by the caller afterward.
    func sendPriceDropNotification(for item: TrackingItem, newPrice: Decimal, currency: String) async {
        let content = UNMutableNotificationContent()

        let isJapanese = Locale.current.language.languageCode?.identifier == "ja"

        if isJapanese {
            content.title = "\(item.displayTitle) が値下がりしました"
        } else {
            content.title = "\(item.displayTitle) Price Drop"
        }

        let oldFormatted = NotificationService.formatPrice(item.baselinePriceDecimal, currency: item.baselineCurrency)
        let newFormatted = NotificationService.formatPrice(newPrice, currency: currency)
        content.body = "\(oldFormatted) → \(newFormatted) (\(item.domain))"
        content.userInfo = ["itemID": item.id.uuidString]
        content.categoryIdentifier = "PRICE_DROP"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "price-drop-\(item.id.uuidString)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil  // deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            item.lastNotifiedPriceDecimal = newPrice
        } catch {
            // Notification delivery failure is non-fatal; log but do not rethrow
            print("NotificationService: failed to schedule notification: \(error)")
        }
    }

    // MARK: - Formatting

    /// Formats a price value with its currency symbol using the device locale.
    ///
    /// Examples: `"¥1,980"` for JPY, `"$19.99"` for USD.
    ///
    /// `NumberFormatter` is cached per currency code because formatter initialisation
    /// is expensive and this method is called in every `ItemCardView` render cycle.
    static func formatPrice(_ price: Decimal, currency: String) -> String {
        let formatter = cachedFormatter(for: currency)
        let nsPrice = NSDecimalNumber(decimal: price)
        return formatter.string(from: nsPrice) ?? "\(currency) \(price)"
    }

    // MARK: - Private Helpers

    /// Thread-safe formatter cache (keyed by currency code).
    private static let formatterCacheLock = NSLock()
    private static var formatterCache: [String: NumberFormatter] = [:]

    private static func cachedFormatter(for currencyCode: String) -> NumberFormatter {
        formatterCacheLock.lock()
        defer { formatterCacheLock.unlock() }
        if let cached = formatterCache[currencyCode] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        if let locale = preferredLocale(for: currencyCode) {
            formatter.locale = locale
        }
        formatterCache[currencyCode] = formatter
        return formatter
    }

    private static func preferredLocale(for currencyCode: String) -> Locale? {
        switch currencyCode {
        case "JPY": return Locale(identifier: "ja_JP")
        case "USD": return Locale(identifier: "en_US")
        case "EUR": return Locale(identifier: "de_DE")
        case "GBP": return Locale(identifier: "en_GB")
        default:    return nil
        }
    }
}
