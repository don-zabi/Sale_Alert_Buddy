import Foundation
import CoreData
import UIKit
import Observation
import WebKit

/// ViewModel for the Add Item sheet.
///
/// `@MainActor` ensures that all UI-state mutations (isRegistering, errorMessage, etc.)
/// happen on the main thread. Core Data operations use `viewContext` which is also
/// main-thread-bound, so this isolation is correct and safe.
@MainActor
@Observable
final class AddItemViewModel {

    struct RegistrationReviewDialog: Equatable {
        enum Kind: Equatable {
            case detected
            case failed
        }

        let kind: Kind
        let title: String
        let message: String
        /// When `true`, the alternative button label is "検出不可なため閉じる" (dismiss sheet).
        /// When `false`, the label is "別の方法で確認" (trigger a silent background retry).
        let isLastAttempt: Bool

        // Rich preview data — non-nil for `.detected` dialogs only.
        let previewImageURL: String?
        let previewTitle: String?
        /// Price already formatted for display (e.g. "¥5,000").
        let previewPrice: String?
        /// The page URL to load in the inline WKWebView for visual price confirmation.
        let previewURL: URL?
        /// Raw decimal value of the detected price; passed to JS to scroll/highlight it.
        let previewPriceDecimal: Decimal?
    }

    // MARK: - Input State

    var urlText: String = ""
    var titleText: String = ""
    var categoryText: String = ""
    var memo: String = ""
    var notificationConditionType: NotificationConditionType = .percentage
    /// Numeric text for notification condition. Examples: "5" (%), "500" (JPY)
    var notificationConditionValueText: String = "1"

    // MARK: - Operation State

    var isRegistering: Bool = false
    var errorMessage: String?
    var registeredItem: TrackingItem?
    var reviewDialog: RegistrationReviewDialog?
    /// Non-nil when the in-app browser capture was blocked by the site's anti-bot system.
    /// The AddItemSheet observes this: it presents an alert then dismisses itself.
    var securityBlockMessage: String? = nil
    /// True after the user taps "この価格で登録" in the review card.
    /// The form stays open so memo/notification conditions can be adjusted before final save.
    var priceConfirmed: Bool = false
    /// Screenshot captured from the product page on the 1st detection attempt.
    /// Shown in the review card in place of a live WebView to avoid confusing UI elements.
    var previewScreenshot: UIImage? = nil

    // Whether the user has already consumed the first background retry.
    // The second attempt always shows "検出不可なため閉じる" regardless of outcome.
    private var isSecondAttempt: Bool = false

    private var preparedDraft: PreparedTrackingItemDraft?

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
                  URLNormalizer.normalize(string) != nil {
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

        guard parsedNotificationConditionValue != nil else {
            errorMessage = String(
                localized: "addItem.error.notificationValue",
                defaultValue: "Enter a valid notification value greater than 0.",
                locale: locale
            )
            return
        }

        isSecondAttempt = false
        priceConfirmed = false
        previewScreenshot = nil
        isRegistering = true
        errorMessage = nil
        reviewDialog = nil

        do {
            let draft = try await checkService.prepareRegistration(
                urlString: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                context: context
            )
            preparedDraft = draft
            reviewDialog = makeDetectedDialog(for: draft)
            // Start capturing a screenshot of the price element for the review card.
            // This runs concurrently so the dialog appears immediately.
            Task { [weak self] in
                guard let self else { return }
                self.previewScreenshot = await PageSnapshotService.shared.capture(
                    url: draft.finalURL,
                    priceDecimal: draft.priceResult.price
                )
            }
        } catch let checkError as PriceCheckError {
            handlePreparationError(checkError)
        } catch {
            errorMessage = error.localizedDescription
        }

        isRegistering = false
    }

    /// Clears any displayed error message.
    func clearError() {
        errorMessage = nil
    }

    /// Called when the user taps "この価格で登録" in the review card.
    /// Closes the card and returns to the form so memo/notification conditions can be set.
    func confirmPrice() {
        reviewDialog = nil
        priceConfirmed = true
    }

    func confirmPreparedRegistration(context: NSManagedObjectContext) {
        guard let preparedDraft else { return }
        guard let conditionValue = parsedNotificationConditionValue else {
            errorMessage = String(
                localized: "addItem.error.notificationValue",
                defaultValue: "Enter a valid notification value greater than 0."
            )
            return
        }

        do {
            registeredItem = try checkService.finalizeRegistration(
                from: preparedDraft,
                memo: memo.isEmpty ? nil : memo,
                tags: [],
                category: categoryText,
                customTitle: titleText.isEmpty ? nil : titleText,
                notificationConditionType: notificationConditionType,
                notificationConditionValue: conditionValue,
                context: context
            )
            reviewDialog = nil
        } catch let checkError as PriceCheckError {
            errorMessage = checkError.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Performs a silent background second attempt at price retrieval.
    ///
    /// Called when the user taps "別の方法で確認" on the detected-price dialog.
    /// Unlike the old flow, this does NOT open the in-app browser; it simply
    /// refetches the URL in the background and shows the result in a new dialog.
    /// After this call the result dialog always shows "検出不可なため閉じる"
    /// (no further retries are offered).
    func retryInBackground(context: NSManagedObjectContext) async {
        reviewDialog = nil
        isSecondAttempt = true
        previewScreenshot = nil   // 2nd attempt uses live WebView, no screenshot needed
        isRegistering = true
        errorMessage = nil

        do {
            let draft = try await checkService.prepareRegistration(
                urlString: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                context: context
            )
            preparedDraft = draft
            // isSecondAttempt == true → isLastAttempt == true in the dialog
            reviewDialog = makeDetectedDialog(for: draft)
        } catch let checkError as PriceCheckError {
            handlePreparationError(checkError)
        } catch {
            errorMessage = error.localizedDescription
        }

        isRegistering = false
    }

    // MARK: - In-App Browser Capture (used by ItemListView for manual re-checks)

    func handleManualCapture(
        html: String,
        pageURL: URL,
        context: NSManagedObjectContext
    ) async -> InAppPriceCaptureResponse {
        isRegistering = true
        defer { isRegistering = false }

        do {
            let draft = try await checkService.prepareRegistrationFromLoadedPage(
                originalUrlString: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                pageHTML: html,
                pageURL: pageURL,
                context: context
            )
            preparedDraft = draft
            reviewDialog = makeDetectedDialog(for: draft)
            return InAppPriceCaptureResponse(shouldDismiss: true, message: "")
        } catch PriceCheckError.accessBlocked {
            securityBlockMessage = String(
                localized: "addItem.error.securityBlock",
                defaultValue: "リンク先サイトのセキュリティ機能により自動で取得することができませんでした。申し訳ございません"
            )
            return InAppPriceCaptureResponse(shouldDismiss: true, message: "")
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

    // MARK: - Private Helpers

    private func makeDetectedDialog(for draft: PreparedTrackingItemDraft) -> RegistrationReviewDialog {
        let priceText = NotificationService.formatPrice(
            draft.priceResult.price,
            currency: draft.priceResult.currency
        )
        return RegistrationReviewDialog(
            kind: .detected,
            title: String(
                localized: "addItem.review.detected.title",
                defaultValue: "価格を検出しました"
            ),
            message: String(
                format: String(
                    localized: "addItem.review.detected.message",
                    defaultValue: "取得価格: %@\n\n正しく検出できていますか？"
                ),
                priceText
            ),
            // After a second attempt the user can no longer retry
            isLastAttempt: isSecondAttempt,
            previewImageURL: draft.metadata.imageUrl,
            previewTitle: draft.metadata.title,
            previewPrice: priceText,
            // 1st attempt → nil (review card shows screenshot captured by PageSnapshotService)
            // 2nd attempt → actual URL (review card shows live WKWebView)
            previewURL: isSecondAttempt ? draft.finalURL : nil,
            previewPriceDecimal: draft.priceResult.price
        )
    }

    private func handlePreparationError(_ error: PriceCheckError) {
        switch error {
        case .accessBlocked, .priceNotFound, .fetchFailed:
            // All failures → give-up dialog; no further retries offered.
            reviewDialog = RegistrationReviewDialog(
                kind: .failed,
                title: String(
                    localized: "addItem.review.failed.title",
                    defaultValue: "価格を取得できませんでした"
                ),
                message: error.errorDescription ?? "",
                isLastAttempt: true,
                previewImageURL: nil,
                previewTitle: nil,
                previewPrice: nil,
                previewURL: nil,
                previewPriceDecimal: nil
            )
        case .invalidURL, .duplicateURL:
            errorMessage = error.errorDescription
        }
    }
}
