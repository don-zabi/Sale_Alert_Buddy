import Foundation
import CoreData
import UIKit
import Observation

/// ViewModel for the Add Item sheet.
///
/// `@MainActor` ensures that all UI-state mutations (isRegistering, errorMessage, etc.)
/// happen on the main thread. Core Data operations use `viewContext` which is also
/// main-thread-bound, so this isolation is correct and safe.
@MainActor
@Observable
final class AddItemViewModel {

    // MARK: - Input State

    var urlText: String = ""
    var titleText: String = ""
    var categoryText: String = ""
    var memo: String = ""
    /// Comma-separated tag input, e.g. "sale, electronics, japan"
    var tagsText: String = ""
    var notificationConditionType: NotificationConditionType = .percentage
    /// Numeric text for notification condition. Examples: "5" (%), "500" (JPY)
    var notificationConditionValueText: String = "1"

    // MARK: - Operation State

    var isRegistering: Bool = false
    var errorMessage: String?
    var registeredItem: TrackingItem?

    // MARK: - Service

    private let checkService: PriceCheckService

    init(checkService: PriceCheckService = .shared) {
        self.checkService = checkService
    }

    // MARK: - Computed Properties

    /// True when a URL has been entered and no registration is in-flight.
    var canRegister: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        parsedNotificationConditionValue != nil &&
        !isRegistering
    }

    /// Tags parsed from comma-separated `tagsText`, trimmed and filtered.
    var parsedTags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var parsedNotificationConditionValue: Double? {
        let trimmed = notificationConditionValueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    func setDefaultConditionValue(for type: NotificationConditionType) {
        switch type {
        case .percentage:
            notificationConditionValueText = "1"
        case .amount:
            notificationConditionValueText = "100"
        case .targetPrice:
            notificationConditionValueText = "1000"
        }
    }

    // MARK: - Actions

    /// Reads a URL from the system clipboard and populates `urlText`.
    ///
    /// Accepts either a URL object on the pasteboard or a string that looks like a URL.
    func pasteFromClipboard() {
        let pasteboard = UIPasteboard.general
        if let url = pasteboard.url {
            urlText = url.absoluteString
        } else if let string = pasteboard.string,
                  string.hasPrefix("http://") || string.hasPrefix("https://") {
            urlText = string
        }
    }

    /// Registers a new tracking item.
    ///
    /// Plan-limit check runs first: if the free tier limit has been reached,
    /// `errorMessage` is set and the method returns early without a network call.
    ///
    /// - Parameter context: The managed object context to create the item in.
    func register(context: NSManagedObjectContext) async {
        // TODO: check StoreKit subscription status for Phase 2 to determine the real limit
        let freePlanLimit = 20

        // Resolve the user-selected in-app locale so error messages appear in the chosen language.
        // `String(localized:)` uses the bundle locale (device language), not the SwiftUI environment
        // locale, so we must pass it explicitly here.
        let locale = Locale(identifier: UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en")

        // Fetch current item count for plan limit enforcement
        let countRequest = TrackingItem.fetchRequest()
        let currentCount: Int
        do {
            currentCount = try context.count(for: countRequest)
        } catch {
            errorMessage = String(localized: "addItem.error.fetch",
                                  defaultValue: "Failed to check existing items.", locale: locale)
            return
        }

        if currentCount >= freePlanLimit {
            errorMessage = String(localized: "addItem.error.planLimit",
                                  defaultValue: "Free plan limit reached (20 items). Upgrade to track more products.",
                                  locale: locale)
            return
        }

        guard let conditionValue = parsedNotificationConditionValue else {
            errorMessage = String(
                localized: "addItem.error.notificationValue",
                defaultValue: "Enter a valid notification value greater than 0.",
                locale: locale
            )
            return
        }

        isRegistering = true
        errorMessage = nil

        do {
            let item = try await checkService.registerItem(
                urlString: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                memo: memo.isEmpty ? nil : memo,
                tags: parsedTags,
                category: categoryText,
                customTitle: titleText.isEmpty ? nil : titleText,
                notificationConditionType: notificationConditionType,
                notificationConditionValue: conditionValue,
                context: context
            )
            registeredItem = item
        } catch let checkError as PriceCheckError {
            errorMessage = checkError.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isRegistering = false
    }

    /// Clears any displayed error message.
    func clearError() {
        errorMessage = nil
    }
}
