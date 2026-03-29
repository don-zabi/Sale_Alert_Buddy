import Foundation
import CoreData
import Observation

/// Errors thrown by PriceCheckService.registerItem.
enum PriceCheckError: Error, LocalizedError {
    case invalidURL
    case duplicateURL(existingItem: TrackingItem)
    case priceNotFound
    case fetchFailed(underlying: Error)

    var errorDescription: String? {
        let locale = Locale(identifier: UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en")
        switch self {
        case .invalidURL:
            return String(
                localized: "priceCheckError.invalidURL",
                defaultValue: "The URL is invalid or could not be normalized.",
                locale: locale
            )
        case .duplicateURL:
            return String(
                localized: "priceCheckError.duplicateURL",
                defaultValue: "This URL is already being tracked.",
                locale: locale
            )
        case .priceNotFound:
            return String(
                localized: "priceCheckError.priceNotFound",
                defaultValue: "Could not find a price on the page.",
                locale: locale
            )
        case .fetchFailed(let error):
            let format = String(
                localized: "priceCheckError.fetchFailed",
                defaultValue: "Failed to fetch the page: %@",
                locale: locale
            )
            return String(format: format, error.localizedDescription)
        }
    }
}

/// Orchestrates price checking: fetch HTML, extract price, update Core Data, send notifications.
///
/// `@MainActor` ensures `isChecking` / `checkProgress` mutations are always on the main thread
/// (required by `@Observable` + SwiftUI). Network fetches suspend the main actor and execute
/// on URLSession's internal queue, so concurrent downloads still happen off-thread.
/// Core Data operations use `viewContext` on the main thread (correct threading model).
@MainActor
@Observable
final class PriceCheckService {

    // MARK: - Shared Instance

    static let shared = PriceCheckService()

    // MARK: - Observable State

    private(set) var isChecking: Bool = false
    private(set) var checkProgress: Double = 0  // 0.0 to 1.0

    // MARK: - Dependencies

    private let fetcher: HTMLFetcher
    private let pipeline: PriceExtractionPipeline
    private let metadataExtractor: MetadataExtractor
    private let throttler: DomainThrottler
    private let notificationService: NotificationService

    // MARK: - Init

    // Swift 5 with MainActor isolation: provide nil-default and resolve lazily
    // to avoid the "nonisolated context" warning for @MainActor static properties.
    init(
        fetcher: HTMLFetcher = HTMLFetcher(),
        pipeline: PriceExtractionPipeline = PriceExtractionPipeline(),
        metadataExtractor: MetadataExtractor = MetadataExtractor(),
        throttler: DomainThrottler = DomainThrottler.shared,
        notificationService: NotificationService? = nil
    ) {
        self.fetcher = fetcher
        self.pipeline = pipeline
        self.metadataExtractor = metadataExtractor
        self.throttler = throttler
        self.notificationService = notificationService ?? NotificationService.shared
    }

    // MARK: - Register Item

    /// Registers a new tracking item by fetching the URL and extracting price + metadata.
    ///
    /// - Parameters:
    ///   - urlString: Raw URL string entered by the user.
    ///   - memo: Optional user note.
    ///   - tags: Array of tag strings.
    ///   - context: Managed object context on which to create the item.
    /// - Returns: The newly created and saved `TrackingItem`.
    /// - Throws: `PriceCheckError` on failure.
    func registerItem(
        urlString: String,
        memo: String?,
        tags: [String],
        category: String? = nil,
        customTitle: String? = nil,
        notificationConditionType: NotificationConditionType = .percentage,
        notificationConditionValue: Double = 1.0,
        context: NSManagedObjectContext
    ) async throws -> TrackingItem {
        // 1. Normalize URL
        guard let normalizedUrl = URLNormalizer.normalize(urlString) else {
            throw PriceCheckError.invalidURL
        }
        guard let url = URL(string: normalizedUrl) else {
            throw PriceCheckError.invalidURL
        }

        // 2. Extract domain
        let domain = url.host ?? ""

        // 3. Check for duplicate
        let duplicateRequest = TrackingItem.fetchRequest()
        duplicateRequest.predicate = NSPredicate(format: "currentUrl == %@", normalizedUrl)
        duplicateRequest.fetchLimit = 1
        let existing = try? context.fetch(duplicateRequest)
        if let existingItem = existing?.first {
            throw PriceCheckError.duplicateURL(existingItem: existingItem)
        }

        // 4. Wait for throttler
        try? await throttler.waitIfNeeded(for: domain)

        // 5. Fetch HTML
        let fetchResult: HTMLFetcher.FetchResult
        do {
            fetchResult = try await fetcher.fetch(url: url)
        } catch {
            throw PriceCheckError.fetchFailed(underlying: error)
        }

        // 6. Extract metadata
        let metadata = metadataExtractor.extract(from: fetchResult.html, requestUrl: fetchResult.finalURL)
        let trimmedCustomTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 7. Extract price
        guard let (priceResult, _) = pipeline.extract(from: fetchResult.html) else {
            throw PriceCheckError.priceNotFound
        }

        // 8. Create TrackingItem
        let item = TrackingItem.create(in: context)
        item.originalUrl = urlString
        item.currentUrl = normalizedUrl
        item.resolvedUrl = metadata.resolvedUrl ?? fetchResult.finalURL.absoluteString
        item.domain = domain
        item.baselinePriceDecimal = priceResult.price
        item.baselineCurrency = priceResult.currency
        item.latestPriceDecimal = priceResult.price
        item.latestCurrency = priceResult.currency
        item.productTitle = (trimmedCustomTitle?.isEmpty == false) ? trimmedCustomTitle : metadata.title
        item.imageUrl = metadata.imageUrl
        item.productIdHintsArray = metadata.productIdHints
        item.itemCategory = category
        item.memo = memo
        item.tagsArray = tags
        item.itemNotificationConditionType = notificationConditionType
        item.itemNotificationConditionValue = notificationConditionValue
        item.lastCheckedAt = Date()
        item.lastSuccessAt = Date()
        item.itemStatus = .ok

        // 9. Save
        PersistenceController.shared.save(context: context)

        return item
    }

    // MARK: - Check Single Item

    /// Fetches the latest price for `item` and updates its Core Data state.
    ///
    /// Returns early without error if the item is paused. On success, sends a notification
    /// if the price dropped sufficiently. On failure, increments the consecutive failure
    /// counter and transitions to `.tempFailed` or `.paused` as appropriate.
    ///
    /// - Parameters:
    ///   - item: The item to check.
    ///   - context: The managed object context owning `item`.
    ///   - timeout: Per-request timeout in seconds.
    func checkItem(
        _ item: TrackingItem,
        context: NSManagedObjectContext,
        timeout: TimeInterval = 15
    ) async {
        // Guard: skip paused items
        guard item.itemStatus != .paused else { return }

        let domain = item.domain
        guard let url = URL(string: item.currentUrl) else {
            item.failCountConsecutive += 1
            item.itemLastErrorType = .network
            item.itemStatus = item.failCountConsecutive >= 3 ? .paused : .tempFailed
            if item.failCountConsecutive >= 3 {
                item.itemPauseReason = .consecutiveFailures
            }
            item.lastCheckedAt = Date()
            item.updatedAt = Date()
            PersistenceController.shared.save(context: context)
            return
        }

        // Wait for throttle
        try? await throttler.waitIfNeeded(for: domain)

        do {
            // Attempt fetch
            let fetchResult = try await fetcher.fetch(url: url, timeout: timeout)

            // Attempt extraction
            guard let (priceResult, extractMethod) = pipeline.extract(from: fetchResult.html) else {
                // Extraction failed — treat as failure
                await handleExtractionFailure(item: item, domain: domain, context: context, durationMs: fetchResult.durationMs, httpStatus: fetchResult.httpStatus)
                return
            }

            // --- Success path ---
            item.itemStatus = .ok
            item.failCountConsecutive = 0
            item.latestPriceDecimal = priceResult.price
            item.latestCurrency = priceResult.currency
            item.lastCheckedAt = Date()
            item.lastSuccessAt = Date()
            item.updatedAt = Date()
            item.itemLastErrorType = .none

            await throttler.recordSuccess(for: domain)

            // Create success log
            let log = FetchLog.create(
                for: item,
                outcome: .success,
                httpStatus: Int16(fetchResult.httpStatus),
                errorType: .none,
                extractMethod: extractMethod,
                durationMs: fetchResult.durationMs,
                note: FetchLog.makePriceNote(price: priceResult.price, currency: priceResult.currency),
                context: context
            )
            item.addFetchLogAndRotate(log, context: context)

            // Check notification conditions (both service and PriceCheckService are @MainActor)
            let shouldSend = notificationService.shouldNotify(
                item: item,
                newPrice: priceResult.price,
                currency: priceResult.currency
            )
            if shouldSend {
                await notificationService.sendPriceDropNotification(
                    for: item,
                    newPrice: priceResult.price,
                    currency: priceResult.currency
                )
            }

            PersistenceController.shared.save(context: context)

        } catch let fetchError as HTMLFetchError {
            await handleHTMLFetchError(
                fetchError,
                item: item,
                domain: domain,
                context: context
            )
        } catch {
            // Unexpected error — treat as network failure
            item.failCountConsecutive += 1
            item.itemLastErrorType = .network
            item.lastCheckedAt = Date()
            item.updatedAt = Date()
            item.itemStatus = item.failCountConsecutive >= 3 ? .paused : .tempFailed
            if item.failCountConsecutive >= 3 {
                item.itemPauseReason = .consecutiveFailures
            }
            let log = FetchLog.create(
                for: item,
                outcome: .failure,
                errorType: .network,
                durationMs: 0,
                context: context
            )
            item.addFetchLogAndRotate(log, context: context)
            PersistenceController.shared.save(context: context)
        }
    }

    // MARK: - Check All

    /// Checks all active (non-paused) items concurrently, up to `maxConcurrent` at a time.
    ///
    /// Updates `isChecking` and `checkProgress` as items complete.
    /// Pass `maxConcurrent: 2` and a shorter `timeout` from a background extension.
    func checkAll(
        context: NSManagedObjectContext,
        maxConcurrent: Int = 5,
        timeout: TimeInterval = 15
    ) async {
        isChecking = true
        checkProgress = 0

        let items: [TrackingItem]
        do {
            items = try context.fetch(TrackingItem.activeItemsFetchRequest())
        } catch {
            isChecking = false
            checkProgress = 1.0
            return
        }

        let total = items.count
        guard total > 0 else {
            isChecking = false
            checkProgress = 1.0
            return
        }

        // Use an actor-isolated counter to track completion safely
        let counter = CompletionCounter()

        // Capture objectIDs (Sendable) instead of NSManagedObjects (non-Sendable)
        // to cross task-group boundaries safely.
        let itemIDs = items.map { $0.objectID }

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0

            for objectID in itemIDs {
                // Throttle concurrency: drain one slot before adding more.
                // NOTE: do NOT increment the counter here — only the drain loop below
                // increments, preventing double-counting when throttle triggers.
                if inFlight >= maxConcurrent {
                    await group.next()
                    inFlight -= 1
                }

                group.addTask { [weak self] in
                    guard let self else { return }
                    // Resolve the managed object within the correct context.
                    guard let item = try? context.existingObject(with: objectID) as? TrackingItem else { return }
                    await self.checkItem(item, context: context, timeout: timeout)
                }
                inFlight += 1
            }

            // Single increment path — avoids double-counting items drained above.
            for await _ in group {
                let completed = await counter.increment()
                checkProgress = Double(completed) / Double(total)
            }
        }

        isChecking = false
        checkProgress = 1.0
    }

    // MARK: - Private Error Handlers

    private func handleExtractionFailure(
        item: TrackingItem,
        domain: String,
        context: NSManagedObjectContext,
        durationMs: Int32,
        httpStatus: Int
    ) async {
        item.failCountConsecutive += 1
        item.itemLastErrorType = .extractionFailed
        item.lastHttpStatus = Int16(httpStatus)
        item.lastCheckedAt = Date()
        item.updatedAt = Date()
        item.itemStatus = item.failCountConsecutive >= 3 ? .paused : .tempFailed
        if item.failCountConsecutive >= 3 {
            item.itemPauseReason = .consecutiveFailures
        }

        let log = FetchLog.create(
            for: item,
            outcome: .failure,
            httpStatus: Int16(httpStatus),
            errorType: .extractionFailed,
            durationMs: durationMs,
            context: context
        )
        item.addFetchLogAndRotate(log, context: context)
        PersistenceController.shared.save(context: context)
    }

    private func handleHTMLFetchError(
        _ error: HTMLFetchError,
        item: TrackingItem,
        domain: String,
        context: NSManagedObjectContext
    ) async {
        item.failCountConsecutive += 1
        item.lastCheckedAt = Date()
        item.updatedAt = Date()
        item.itemLastErrorType = error.fetchErrorType

        let httpStatus: Int16
        if let code = error.httpStatusCode {
            httpStatus = Int16(code)
            item.lastHttpStatus = httpStatus
        } else {
            httpStatus = 0
        }

        let log = FetchLog.create(
            for: item,
            outcome: .failure,
            httpStatus: httpStatus == 0 ? nil : httpStatus,
            errorType: error.fetchErrorType,
            durationMs: 0,
            context: context
        )
        item.addFetchLogAndRotate(log, context: context)

        // Throttler feedback
        let shouldPauseDomain = await throttler.recordFailure(
            for: domain,
            httpStatus: error.httpStatusCode
        )

        // 429 or 403 → immediate pause
        if case .http4xx(let code) = error, code == 429 || code == 403 {
            item.itemStatus = .paused
            item.itemPauseReason = .consecutiveFailures
        } else if shouldPauseDomain {
            // 3× 403 across calls → pause this item
            item.itemStatus = .paused
            item.itemPauseReason = .consecutiveFailures
        } else if item.failCountConsecutive >= 3 {
            item.itemStatus = .paused
            item.itemPauseReason = .consecutiveFailures
        } else {
            item.itemStatus = .tempFailed
        }

        PersistenceController.shared.save(context: context)
    }
}

// MARK: - CompletionCounter

/// Thread-safe counter for tracking task completion in checkAll.
private actor CompletionCounter {
    private var count: Int = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}
