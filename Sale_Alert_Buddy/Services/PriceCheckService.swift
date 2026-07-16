import Foundation
import CoreData
import Observation
import OSLog

/// Errors thrown by PriceCheckService.registerItem.
enum PriceCheckError: Error, LocalizedError {
    case invalidURL
    case unsupportedSite
    case duplicateURL(existingItem: TrackingItem)
    case priceNotFound
    case accessBlocked
    case reviewRequired
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
        case .unsupportedSite:
            return String(
                localized: "priceCheckError.unsupportedSite",
                defaultValue: "This build only supports Amazon and Mercari. Please enter an Amazon or Mercari product URL.",
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
        case .accessBlocked:
            return String(
                localized: "priceCheckError.accessBlocked",
                defaultValue: "This site showed a verification or anti-bot page, so the app could not read the product price.",
                locale: locale
            )
        case .reviewRequired:
            return String(
                localized: "priceCheckError.reviewRequired",
                defaultValue: "Price candidates were found, but confidence was low. Please confirm the price manually.",
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

struct PreparedTrackingItemDraft: Sendable {
    let originalUrlString: String
    let normalizedUrl: String
    let finalURL: URL
    let resolvedUrlString: String
    let domain: String
    let metadata: PageMetadata
    let priceResult: PriceResult
    let extractMethod: ExtractMethod
}

struct ForegroundPriceCaptureResult: Sendable {
    let priceResult: PriceResult
    let extractMethod: ExtractMethod
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

    private static let resolutionLogger = Logger(
        subsystem: "SaleAlertBuddy",
        category: "PriceResolution"
    )

    // MARK: - Shared Instance

    static let shared = PriceCheckService()

    // MARK: - Observable State

    private(set) var isChecking: Bool = false
    private(set) var checkProgress: Double = 0  // 0.0 to 1.0

    /// Timestamp of the most recent checkAll invocation (foreground or background).
    /// Used to enforce a minimum interval between full checks so the app doesn't
    /// hammer the network every time the user briefly backgrounds and re-foregrounds.
    private var lastCheckAllDate: Date? = nil

    // MARK: - Dependencies

    private let fetcher: HTMLFetcher
    private let pipeline: PriceExtractionPipeline
    private let sitePriceResolver: any SiteSpecificPriceResolving
    private let metadataExtractor: MetadataExtractor
    private let throttler: DomainThrottler
    private let notificationService: NotificationService
    private let renderedPageLoader: any RenderedPageLoading

    // MARK: - Init

    // Swift 5 with MainActor isolation: provide nil-default and resolve lazily
    // to avoid the "nonisolated context" warning for @MainActor static properties.
    init(
        fetcher: HTMLFetcher? = nil,
        pipeline: PriceExtractionPipeline = PriceExtractionPipeline(),
        sitePriceResolver: (any SiteSpecificPriceResolving)? = nil,
        metadataExtractor: MetadataExtractor = MetadataExtractor(),
        throttler: DomainThrottler = DomainThrottler.shared,
        notificationService: NotificationService? = nil,
        renderedPageLoader: (any RenderedPageLoading)? = nil
    ) {
        let sharedSession = HTMLFetcher.makeDefaultSession()

        self.fetcher = fetcher ?? HTMLFetcher(session: sharedSession)
        self.pipeline = pipeline
        self.sitePriceResolver = sitePriceResolver ?? SiteSpecificPriceResolver(session: sharedSession)
        self.metadataExtractor = metadataExtractor
        self.throttler = throttler
        self.notificationService = notificationService ?? NotificationService.shared
        self.renderedPageLoader = renderedPageLoader ?? WebKitRenderedPageLoader.shared
    }

    // MARK: - Registration Draft

    func prepareRegistration(
        urlString: String,
        context: NSManagedObjectContext
    ) async throws -> PreparedTrackingItemDraft {
        let preparedURL = try prepareNormalizedURL(from: urlString)
        guard SupportedShop.isSupported(url: preparedURL.url) else {
            throw PriceCheckError.unsupportedSite
        }
        try throwIfDuplicate(url: preparedURL.normalizedUrl, context: context)
        try? await throttler.waitIfNeeded(for: preparedURL.url.host ?? "")

        let fetchResult: HTMLFetcher.FetchResult
        do {
            fetchResult = try await fetcher.fetch(url: preparedURL.url)
        } catch {
            if let renderedPage = await renderedPageLoader.load(url: preparedURL.url) {
                let resolvedPage = try await makeResolvedPage(
                    from: renderedPage.html,
                    requestURL: renderedPage.finalURL,
                    httpStatus: 200,
                    durationMs: 0,
                    allowURLFallback: true,
                    renderedSnapshot: renderedPage,
                    preferRenderedVisiblePrice: true
                )
                return makeDraft(
                    originalUrlString: urlString,
                    normalizedUrl: preparedURL.normalizedUrl,
                    resolvedPage: resolvedPage
                )
            }
            throw PriceCheckError.fetchFailed(underlying: error)
        }

        let resolvedPage = try await makeResolvedPage(
            from: fetchResult.html,
            requestURL: fetchResult.finalURL,
            httpStatus: fetchResult.httpStatus,
            durationMs: fetchResult.durationMs,
            allowURLFallback: true,
            preferRenderedVisiblePrice: true
        )
        return makeDraft(
            originalUrlString: urlString,
            normalizedUrl: preparedURL.normalizedUrl,
            resolvedPage: resolvedPage
        )
    }

    func prepareRegistrationFromLoadedPage(
        originalUrlString: String,
        pageHTML: String,
        pageURL: URL,
        context: NSManagedObjectContext,
        visiblePriceResult: PriceResult? = nil,
        visiblePriceCandidates: [PriceCandidate] = [],
        selectedPriceCandidate: PriceCandidate? = nil
    ) async throws -> PreparedTrackingItemDraft {
        let preparedURL = try prepareNormalizedURL(
            from: URLNormalizer.normalize(originalUrlString) ?? pageURL.absoluteString
        )
        guard SupportedShop.isSupported(url: pageURL) || SupportedShop.isSupported(url: preparedURL.url) else {
            throw PriceCheckError.unsupportedSite
        }
        try throwIfDuplicate(url: preparedURL.normalizedUrl, context: context)

        do {
            let resolvedPage = try await resolveLoadedPage(
                pageHTML: pageHTML,
                pageURL: pageURL,
                preferRenderedVisiblePrice: true,
                visiblePriceResult: visiblePriceResult,
                visiblePriceCandidates: visiblePriceCandidates,
                selectedPriceCandidate: selectedPriceCandidate
            )
            return makeDraft(
                originalUrlString: originalUrlString,
                normalizedUrl: preparedURL.normalizedUrl,
                resolvedPage: resolvedPage
            )
        } catch let checkError as PriceCheckError {
            throw checkError
        } catch {
            throw PriceCheckError.fetchFailed(underlying: error)
        }
    }

    func finalizeRegistration(
        from draft: PreparedTrackingItemDraft,
        memo: String?,
        tags: [String],
        category: String? = nil,
        customTitle: String? = nil,
        notificationConditionType: NotificationConditionType = .percentage,
        notificationConditionValue: Double = 1.0,
        context: NSManagedObjectContext
    ) throws -> TrackingItem {
        try throwIfDuplicate(url: draft.normalizedUrl, context: context)

        let item = TrackingItem.create(in: context)
        item.originalUrl = draft.originalUrlString
        item.currentUrl = draft.normalizedUrl
        item.resolvedUrl = draft.resolvedUrlString
        item.domain = draft.domain
        item.baselinePriceDecimal = draft.priceResult.price
        item.baselineCurrency = draft.priceResult.currency
        item.latestPriceDecimal = draft.priceResult.price
        item.latestCurrency = draft.priceResult.currency
        item.productTitle = preferredTitle(customTitle: customTitle, extractedTitle: draft.metadata.title)
        item.imageUrl = draft.metadata.imageUrl
        item.productIdHintsArray = draft.metadata.productIdHints
        item.itemCategory = category
        item.memo = memo
        item.tagsArray = tags
        item.itemNotificationConditionType = notificationConditionType
        item.itemNotificationConditionValue = notificationConditionValue
        item.lastCheckedAt = Date()
        item.lastSuccessAt = Date()
        item.itemStatus = .ok
        item.itemLastErrorType = .none

        PersistenceController.shared.save(context: context)
        return item
    }

    func checkItemUsingLoadedPage(
        _ item: TrackingItem,
        pageHTML: String,
        pageURL: URL,
        context: NSManagedObjectContext,
        visiblePriceResult: PriceResult? = nil,
        visiblePriceCandidates: [PriceCandidate] = [],
        selectedPriceCandidate: PriceCandidate? = nil
    ) async throws -> ForegroundPriceCaptureResult {
        let resolvedPage = try await resolveLoadedPage(
            pageHTML: pageHTML,
            pageURL: pageURL,
            visiblePriceResult: visiblePriceResult,
            visiblePriceCandidates: visiblePriceCandidates,
            selectedPriceCandidate: selectedPriceCandidate
        )
        guard !requiresReview(for: resolvedPage.priceResult) else {
            throw PriceCheckError.reviewRequired
        }
        await applyResolvedPrice(
            item: item,
            domain: item.domain,
            resolvedPage: resolvedPage,
            context: context
        )
        return ForegroundPriceCaptureResult(
            priceResult: resolvedPage.priceResult,
            extractMethod: resolvedPage.extractMethod
        )
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
        let draft = try await prepareRegistration(
            urlString: urlString,
            context: context
        )
        return try finalizeRegistration(
            from: draft,
            memo: memo,
            tags: tags,
            category: category,
            customTitle: customTitle,
            notificationConditionType: notificationConditionType,
            notificationConditionValue: notificationConditionValue,
            context: context
        )
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

        var fetchDurationMs: Int32 = 0
        var fetchHTTPStatus: Int = 0

        do {
            // Attempt fetch
            let fetchResult = try await fetcher.fetch(url: url, timeout: timeout)
            fetchDurationMs = fetchResult.durationMs
            fetchHTTPStatus = fetchResult.httpStatus
            let resolvedPage = try await makeResolvedPage(
                from: fetchResult.html,
                requestURL: fetchResult.finalURL,
                httpStatus: fetchResult.httpStatus,
                durationMs: fetchResult.durationMs,
                allowURLFallback: false
            )

            if requiresReview(for: resolvedPage.priceResult) {
                await handleExtractionFailure(
                    item: item,
                    domain: domain,
                    context: context,
                    durationMs: fetchDurationMs,
                    httpStatus: fetchHTTPStatus,
                    errorType: .extractionFailed,
                    note: lowConfidenceNote(for: resolvedPage.priceResult)
                )
                return
            }

            await applyResolvedPrice(
                item: item,
                domain: domain,
                resolvedPage: resolvedPage,
                context: context
            )

        } catch let checkError as PriceCheckError {
            let errorType: FetchErrorType
            switch checkError {
            case .accessBlocked:
                errorType = .accessBlocked
            case .priceNotFound, .reviewRequired:
                errorType = .extractionFailed
            case .invalidURL, .duplicateURL, .unsupportedSite:
                errorType = .extractionFailed
            case .fetchFailed:
                errorType = .network
            }
            await handleExtractionFailure(
                item: item,
                domain: domain,
                context: context,
                durationMs: fetchDurationMs,
                httpStatus: fetchHTTPStatus,
                errorType: errorType
            )
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
    ///
    /// Guards against concurrent invocations (returns immediately if already running)
    /// and enforces a 5-minute minimum interval between foreground full-checks to
    /// prevent redundant network requests when the user briefly leaves and returns.
    func checkAll(
        context: NSManagedObjectContext,
        maxConcurrent: Int = 5,
        timeout: TimeInterval = 15
    ) async {
        // Guard: prevent concurrent checkAll runs
        guard !isChecking else { return }

        // Guard: enforce minimum 5-minute interval between full checks
        let minimumInterval: TimeInterval = 5 * 60
        if let last = lastCheckAllDate, Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        lastCheckAllDate = Date()

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
        httpStatus: Int,
        errorType: FetchErrorType = .extractionFailed,
        note: String? = nil
    ) async {
        item.failCountConsecutive += 1
        item.itemLastErrorType = errorType
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
            errorType: errorType,
            durationMs: durationMs,
            note: note,
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

    private func resolvePrice(
        from html: String,
        requestURL: URL,
        allowURLFallback: Bool
    ) async -> (result: PriceResult, method: ExtractMethod)? {
        if let siteSpecific = await sitePriceResolver.resolve(
            for: requestURL,
            html: html,
            allowURLFallback: allowURLFallback
        ) {
            return siteSpecific
        }

        if ProtectionPageDetector.isProtectionPage(html, url: requestURL) {
            return nil
        }

        return pipeline.extract(from: html)
    }

    private func resolvePriceOrThrow(
        from html: String,
        requestURL: URL,
        allowURLFallback: Bool
    ) async throws -> (result: PriceResult, method: ExtractMethod) {
        if let resolvedPrice = await resolvePrice(
            from: html,
            requestURL: requestURL,
            allowURLFallback: allowURLFallback
        ) {
            return resolvedPrice
        }

        if ProtectionPageDetector.isProtectionPage(html, url: requestURL) {
            throw PriceCheckError.accessBlocked
        }

        throw PriceCheckError.priceNotFound
    }

    private func resolveRenderedSnapshotPrice(
        _ renderedPage: RenderedPageSnapshot
    ) async throws -> (result: PriceResult, method: ExtractMethod)? {
        if let visiblePrice = renderedPage.visiblePriceResult,
           PriceValidator.validate(visiblePrice) {
            return (result: visiblePrice, method: visiblePrice.extractMethod)
        }

        guard !renderedPage.html.isEmpty else {
            return nil
        }

        return await resolvePrice(
            from: renderedPage.html,
            requestURL: renderedPage.finalURL,
            allowURLFallback: false
        )
    }

    private func shouldUseRenderedVisiblePrice(
        _ renderedPrice: PriceResult,
        over resolvedPrice: (result: PriceResult, method: ExtractMethod)
    ) -> Bool {
        guard PriceValidator.validate(renderedPrice) else { return false }
        guard resolvedPrice.method != .siteAPI else { return false }
        guard renderedPrice.currency.uppercased() == resolvedPrice.result.currency.uppercased() else { return false }
        guard renderedPrice.price != resolvedPrice.result.price else { return false }

        if renderedPrice.confidence >= 0.82 {
            return true
        }

        switch resolvedPrice.method {
        case .schemaOrg, .metaTag, .dataAttribute, .htmlPattern, .embeddedJSON, .htmlContext:
            return renderedPrice.confidence >= max(0.78, resolvedPrice.result.confidence - 0.05)
        case .failed, .siteAPI, .renderedVisible:
            return false
        }
    }

    private func prepareNormalizedURL(from urlString: String) throws -> (normalizedUrl: String, url: URL) {
        guard let normalizedUrl = URLNormalizer.normalize(urlString),
              let url = URL(string: normalizedUrl) else {
            throw PriceCheckError.invalidURL
        }

        return (normalizedUrl, url)
    }

    private func throwIfDuplicate(url normalizedUrl: String, context: NSManagedObjectContext) throws {
        let duplicateRequest = TrackingItem.fetchRequest()
        duplicateRequest.predicate = NSPredicate(format: "currentUrl == %@", normalizedUrl)
        duplicateRequest.fetchLimit = 1

        let existing = try? context.fetch(duplicateRequest)
        if let existingItem = existing?.first {
            throw PriceCheckError.duplicateURL(existingItem: existingItem)
        }
    }

    private func makeDraft(
        originalUrlString: String,
        normalizedUrl: String,
        html: String,
        finalURL: URL,
        httpStatus: Int = 200,
        durationMs: Int32 = 0,
        allowURLFallback: Bool
    ) async throws -> PreparedTrackingItemDraft {
        let resolvedPrice = try await resolvePriceOrThrow(
            from: html,
            requestURL: finalURL,
            allowURLFallback: allowURLFallback
        )
        let metadata = metadataExtractor.extract(from: html, requestUrl: finalURL)
        let resolvedUrlString = metadata.resolvedUrl ?? finalURL.absoluteString
        let resolvedPage = ResolvedPagePrice(
            priceResult: resolvedPrice.result,
            extractMethod: resolvedPrice.method,
            finalURL: finalURL,
            resolvedUrlString: resolvedUrlString,
            metadata: metadata,
            httpStatus: httpStatus,
            durationMs: durationMs
        )
        return makeDraft(
            originalUrlString: originalUrlString,
            normalizedUrl: normalizedUrl,
            resolvedPage: resolvedPage
        )
    }

    private func makeDraft(
        originalUrlString: String,
        normalizedUrl: String,
        resolvedPage: ResolvedPagePrice
    ) -> PreparedTrackingItemDraft {
        PreparedTrackingItemDraft(
            originalUrlString: originalUrlString,
            normalizedUrl: normalizedUrl,
            finalURL: resolvedPage.finalURL,
            resolvedUrlString: resolvedPage.resolvedUrlString,
            domain: URL(string: resolvedPage.resolvedUrlString)?.host ?? resolvedPage.finalURL.host ?? "",
            metadata: resolvedPage.metadata,
            priceResult: resolvedPage.priceResult,
            extractMethod: resolvedPage.extractMethod
        )
    }

    private func resolveLoadedPage(
        pageHTML: String,
        pageURL: URL,
        preferRenderedVisiblePrice: Bool = false,
        visiblePriceResult: PriceResult? = nil,
        visiblePriceCandidates: [PriceCandidate] = [],
        selectedPriceCandidate: PriceCandidate? = nil
    ) async throws -> ResolvedPagePrice {
        let snapshotError: PriceCheckError?
        let capturedSnapshot = RenderedPageSnapshot(
            html: pageHTML,
            finalURL: pageURL,
            visiblePriceResult: visiblePriceResult,
            visiblePriceCandidates: visiblePriceCandidates,
            selectedPriceCandidate: selectedPriceCandidate
        )

        do {
            return try await makeResolvedPage(
                from: pageHTML,
                requestURL: pageURL,
                httpStatus: 200,
                durationMs: 0,
                allowURLFallback: false,
                renderedSnapshot: capturedSnapshot,
                preferRenderedVisiblePrice: preferRenderedVisiblePrice
            )
        } catch let error as PriceCheckError {
            snapshotError = error
        } catch {
            snapshotError = nil
        }

        do {
            let fetchResult = try await fetcher.fetch(url: pageURL)
            return try await makeResolvedPage(
                from: fetchResult.html,
                requestURL: fetchResult.finalURL,
                httpStatus: fetchResult.httpStatus,
                durationMs: fetchResult.durationMs,
                allowURLFallback: false,
                renderedSnapshot: capturedSnapshot,
                preferRenderedVisiblePrice: preferRenderedVisiblePrice
            )
        } catch let error as PriceCheckError {
            throw snapshotError ?? error
        } catch {
            if let snapshotError {
                throw snapshotError
            }
            throw PriceCheckError.fetchFailed(underlying: error)
        }
    }

    private func makeResolvedPage(
        from html: String,
        requestURL: URL,
        httpStatus: Int,
        durationMs: Int32,
        allowURLFallback: Bool,
        renderedSnapshot: RenderedPageSnapshot? = nil,
        preferRenderedVisiblePrice: Bool = false
    ) async throws -> ResolvedPagePrice {
        let rawSource = await analyzePriceSource(
            from: html,
            requestURL: requestURL,
            allowURLFallback: allowURLFallback,
            origin: .rawHTML
        )
        let rawBestCandidate = rawSource.analysis?.bestCandidate?.candidate
        let rawHasMeaningfulContent = rawSource.analysis?.hasMeaningfulContent ?? false
        let rawCandidateNeedsStrongerSignals =
            (rawBestCandidate?.hasPrimarySignal != true) &&
            (rawBestCandidate?.hasAuthoritativeSource != true)
        let rawNeedsRenderedConfirmation =
            rawBestCandidate == nil ||
            rawSource.isProtectionPage ||
            (!rawHasMeaningfulContent && rawBestCandidate?.hasAuthoritativeSource != true) ||
            rawBestCandidate?.hasSevereNegativeSignal == true ||
            rawCandidateNeedsStrongerSignals

        let shouldAttemptRenderedConfirmation =
            renderedSnapshot != nil ||
            rawNeedsRenderedConfirmation

        let liveSnapshot: RenderedPageSnapshot?
        if shouldAttemptRenderedConfirmation {
            if let renderedSnapshot {
                liveSnapshot = renderedSnapshot
            } else {
                liveSnapshot = await renderedPageLoader.load(url: requestURL)
            }
        } else {
            liveSnapshot = nil
        }

        var metadataHTML = html
        var finalURL = requestURL
        var renderedAnalysis: PriceSourceAnalysis?
        let preferredRenderedCandidate = liveSnapshot?.selectedPriceCandidate

        if let liveSnapshot {
            if !liveSnapshot.html.isEmpty {
                metadataHTML = liveSnapshot.html
            }
            finalURL = liveSnapshot.finalURL
            var renderedCandidates = mergedRenderedCandidates(from: liveSnapshot)
            // Re-run the deterministic site resolvers against the hydrated DOM so
            // SPA shops (e.g. Mercari) that expose no price in raw HTML still get an
            // authoritative candidate from the rendered page.
            if !liveSnapshot.html.isEmpty,
               let renderedSiteSpecific = await sitePriceResolver.resolve(
                   for: finalURL,
                   html: liveSnapshot.html,
                   allowURLFallback: false
               ) {
                renderedCandidates.append(
                    PriceCandidateFactory.siteAPICandidate(
                        from: renderedSiteSpecific.result,
                        origin: .siteAPI
                    )
                )
            }
            renderedAnalysis = pipeline.analyze(
                from: liveSnapshot.html,
                origin: .renderedHTML,
                additionalCandidates: renderedCandidates,
                isProtectionPage: !liveSnapshot.html.isEmpty && ProtectionPageDetector.isProtectionPage(liveSnapshot.html, url: liveSnapshot.finalURL)
            )
        }

        guard let report = resolvePriceReport(
            rawSource: rawSource,
            renderedAnalysis: renderedAnalysis,
            preferRenderedVisiblePrice: preferRenderedVisiblePrice,
            requestURL: requestURL,
            preferredRenderedCandidate: preferredRenderedCandidate
        ) else {
            throw rawSource.error ?? PriceCheckError.priceNotFound
        }

        logResolution(report, requestURL: requestURL)

        let metadata = metadataExtractor.extract(from: metadataHTML, requestUrl: finalURL)
        return ResolvedPagePrice(
            priceResult: report.result,
            extractMethod: report.result.extractMethod,
            finalURL: finalURL,
            resolvedUrlString: metadata.resolvedUrl ?? finalURL.absoluteString,
            metadata: metadata,
            httpStatus: httpStatus,
            durationMs: durationMs
        )
    }

    private func analyzePriceSource(
        from html: String,
        requestURL: URL,
        allowURLFallback: Bool,
        origin: PriceCandidateOrigin
    ) async -> SourceEvaluation {
        let siteSpecific = await sitePriceResolver.resolve(
            for: requestURL,
            html: html,
            allowURLFallback: allowURLFallback
        )
        let isProtectionPage = ProtectionPageDetector.isProtectionPage(html, url: requestURL)

        var additionalCandidates: [PriceCandidate] = []
        if let siteSpecific {
            additionalCandidates.append(
                PriceCandidateFactory.siteAPICandidate(
                    from: siteSpecific.result,
                    origin: .siteAPI
                )
            )
        }

        let analysis = pipeline.analyze(
            from: html,
            origin: origin,
            additionalCandidates: additionalCandidates,
            isProtectionPage: isProtectionPage
        )

        let error: PriceCheckError?
        if analysis?.bestCandidate != nil {
            error = nil
        } else if isProtectionPage {
            error = .accessBlocked
        } else {
            error = .priceNotFound
        }

        return SourceEvaluation(
            analysis: analysis,
            error: error,
            isProtectionPage: isProtectionPage
        )
    }

    private func resolvePriceReport(
        rawSource: SourceEvaluation,
        renderedAnalysis: PriceSourceAnalysis?,
        preferRenderedVisiblePrice: Bool,
        requestURL: URL,
        preferredRenderedCandidate: PriceCandidate?
    ) -> PriceResolutionReport? {
        let rawBest = rawSource.analysis?.bestCandidate
        let renderedBest = renderedAnalysis?.bestCandidate

        var combinedCandidates: [ScoredPriceCandidate] = []
        combinedCandidates.append(contentsOf: (rawSource.analysis?.rankedCandidates ?? []).map {
            applyResolverBonus(
                to: $0,
                rawSource: rawSource,
                renderedAnalysis: renderedAnalysis,
                preferRenderedVisiblePrice: preferRenderedVisiblePrice,
                preferredRenderedCandidate: preferredRenderedCandidate
            )
        })
        combinedCandidates.append(contentsOf: (renderedAnalysis?.rankedCandidates ?? []).map {
            applyResolverBonus(
                to: $0,
                rawSource: rawSource,
                renderedAnalysis: renderedAnalysis,
                preferRenderedVisiblePrice: preferRenderedVisiblePrice,
                preferredRenderedCandidate: preferredRenderedCandidate
            )
        })

        combinedCandidates.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.anchorScore != rhs.anchorScore {
                return lhs.anchorScore > rhs.anchorScore
            }
            return lhs.candidate.anchorKey < rhs.candidate.anchorKey
        }

        guard let finalCandidate = combinedCandidates.first else {
            return nil
        }

        let runnerUp = combinedCandidates.dropFirst().first {
            $0.candidate.anchorKey != finalCandidate.candidate.anchorKey ||
            $0.candidate.amountKey != finalCandidate.candidate.amountKey
        }

        let comparisonReasons = comparisonReasons(
            rawBest: rawBest,
            renderedBest: renderedBest,
            finalCandidate: finalCandidate,
            rawSource: rawSource,
            requestURL: requestURL,
            preferredRenderedCandidate: preferredRenderedCandidate
        )
        let confidenceDecision = confidenceDecision(
            finalCandidate: finalCandidate,
            runnerUp: runnerUp,
            rawBest: rawBest,
            renderedBest: renderedBest,
            rawSource: rawSource,
            preferredRenderedCandidate: preferredRenderedCandidate
        )

        let result = pipeline.makeResult(
            from: finalCandidate.candidate,
            confidenceLevel: confidenceDecision.level
        )

        return PriceResolutionReport(
            result: result,
            finalCandidate: finalCandidate,
            rawAnalysis: rawSource.analysis,
            renderedAnalysis: renderedAnalysis,
            combinedCandidates: Array(combinedCandidates.prefix(10)),
            comparisonReasons: comparisonReasons,
            confidenceReasons: confidenceDecision.reasons
        )
    }

    private func applyResolverBonus(
        to ranked: ScoredPriceCandidate,
        rawSource: SourceEvaluation,
        renderedAnalysis: PriceSourceAnalysis?,
        preferRenderedVisiblePrice: Bool,
        preferredRenderedCandidate: PriceCandidate?
    ) -> ScoredPriceCandidate {
        var score = ranked.score
        var adoptionReasons = ranked.adoptionReasons
        var rejectionReasons = ranked.rejectionReasons
        let candidate = ranked.candidate
        let rawBest = rawSource.analysis?.bestCandidate
        let renderedBest = renderedAnalysis?.bestCandidate
        let bestRenderedVisible = renderedAnalysis?.rankedCandidates.first {
            $0.candidate.sourceType == .renderedVisible
        }

        if candidate.sourceType == .siteAPI {
            score += 0.40
            adoptionReasons.append("site-api-authoritative")
        }

        if let preferredRenderedCandidate,
           candidatesMatch(candidate, preferredRenderedCandidate) {
            score += 1.35
            adoptionReasons.append("user-selected")
        }

        if (rawBest == nil || rawSource.isProtectionPage || !(rawSource.analysis?.hasMeaningfulContent ?? false)) && candidate.origin.isRendered {
            score += 0.26
            adoptionReasons.append("render-fallback")
        }

        if candidate.origin.isRendered && candidate.isVisible && candidate.hasPrimarySignal {
            score += 0.12
            adoptionReasons.append("render-primary-signal")
        }

        if candidate.origin == .renderedDOM && candidate.isAboveTheFold {
            score += 0.08
            adoptionReasons.append("render-above-fold")
        }

        if preferRenderedVisiblePrice && candidate.origin.isRendered {
            score += candidate.isVisible ? 0.18 : 0.08
            adoptionReasons.append("prefer-rendered")
        }

        if preferRenderedVisiblePrice && candidate.sourceType == .renderedVisible {
            score += candidate.isVisible ? 0.26 : 0.12
            adoptionReasons.append("prefer-rendered-visible")
        }

        if preferRenderedVisiblePrice,
           let bestRenderedVisible,
           candidate.sourceType == .renderedVisible,
           candidate.amountKey == bestRenderedVisible.candidate.amountKey {
            score += candidate.isVisible ? 0.34 : 0.18
            adoptionReasons.append("prefer-captured-visible")
        }

        if preferRenderedVisiblePrice,
           candidate.origin == .rawHTML,
           bestRenderedVisible?.candidate.isVisible == true {
            score -= 0.10
            rejectionReasons.append("prefer-rendered-over-raw")
        }

        if let rawBest,
           candidate.origin.isRendered,
           candidate.amountKey != rawBest.candidate.amountKey,
           (rawBest.candidate.hasSevereNegativeSignal || !rawBest.candidate.hasPrimarySignal) {
            score += 0.18
            adoptionReasons.append("render-stronger-than-raw")
        }

        if let rawBest,
           let bestRenderedVisible,
           candidate.sourceType == .renderedVisible,
           candidate.amountKey == bestRenderedVisible.candidate.amountKey,
           rawBest.candidate.amountKey != bestRenderedVisible.candidate.amountKey {
            score += 0.18
            adoptionReasons.append("render-visible-mismatch-wins")
        }

        if let renderedBest,
           candidate.origin == .rawHTML,
           renderedBest.candidate.hasPrimarySignal,
           renderedBest.candidate.isVisible,
           !candidate.hasPrimarySignal {
            score -= 0.12
            rejectionReasons.append("weaker-than-render")
        }

        if let bestRenderedVisible,
           candidate.origin == .rawHTML,
           candidate.amountKey != bestRenderedVisible.candidate.amountKey,
           bestRenderedVisible.candidate.isVisible {
            score -= 0.12
            rejectionReasons.append("mismatch-visible-render")
        }

        if let rawBest,
           let renderedBest,
           rawBest.candidate.amountKey == renderedBest.candidate.amountKey,
           candidate.amountKey == rawBest.candidate.amountKey {
            score += 0.18
            adoptionReasons.append("raw-render-agree")
        }

        if rawSource.isProtectionPage && candidate.origin == .rawHTML {
            score -= 0.18
            rejectionReasons.append("raw-protection-page")
        }

        if let preferredRenderedCandidate,
           candidate.origin == .rawHTML,
           !candidatesMatch(candidate, preferredRenderedCandidate) {
            score -= 0.18
            rejectionReasons.append("conflicts-with-user-selection")
        }

        return ScoredPriceCandidate(
            candidate: candidate,
            score: score,
            anchorScore: ranked.anchorScore,
            adoptionReasons: adoptionReasons,
            rejectionReasons: rejectionReasons
        )
    }

    private func comparisonReasons(
        rawBest: ScoredPriceCandidate?,
        renderedBest: ScoredPriceCandidate?,
        finalCandidate: ScoredPriceCandidate,
        rawSource: SourceEvaluation,
        requestURL: URL,
        preferredRenderedCandidate: PriceCandidate?
    ) -> [String] {
        var reasons: [String] = []

        if rawSource.isProtectionPage {
            reasons.append("raw detected protection page")
        }
        if rawBest == nil {
            reasons.append("raw had no candidate")
        }
        if let rawBest, rawBest.candidate.hasSevereNegativeSignal {
            reasons.append("raw top candidate looked auxiliary")
        }
        if let renderedBest, renderedBest.candidate.hasPrimarySignal && renderedBest.candidate.isVisible {
            reasons.append("rendered had visible primary candidate")
        }
        if let rawBest, let renderedBest, rawBest.candidate.amountKey != renderedBest.candidate.amountKey {
            reasons.append("raw/render mismatch")
        }
        if let preferredRenderedCandidate,
           candidatesMatch(finalCandidate.candidate, preferredRenderedCandidate) {
            reasons.append("user selected rendered candidate")
        }
        reasons.append("selected \(finalCandidate.candidate.origin.debugName):\(finalCandidate.candidate.sourceType.debugName)")
        reasons.append("url \(requestURL.absoluteString)")
        return reasons
    }

    private func confidenceDecision(
        finalCandidate: ScoredPriceCandidate,
        runnerUp: ScoredPriceCandidate?,
        rawBest: ScoredPriceCandidate?,
        renderedBest: ScoredPriceCandidate?,
        rawSource: SourceEvaluation,
        preferredRenderedCandidate: PriceCandidate?
    ) -> (level: PriceConfidenceLevel, reasons: [String]) {
        var reasons: [String] = []
        let gap = finalCandidate.score - (runnerUp?.score ?? (finalCandidate.score - 1))
        let rawRenderMismatch = rawBest != nil && renderedBest != nil && rawBest?.candidate.amountKey != renderedBest?.candidate.amountKey
        let rawRenderAgree = rawBest != nil && renderedBest != nil && rawBest?.candidate.amountKey == renderedBest?.candidate.amountKey
        let candidate = finalCandidate.candidate
        let missingPrimarySignal = !candidate.hasPrimarySignal && !candidate.hasAuthoritativeSource

        if candidate.sourceType == .siteAPI {
            reasons.append("site API candidate")
            return (.high, reasons)
        }

        if let preferredRenderedCandidate,
           candidatesMatch(candidate, preferredRenderedCandidate) {
            reasons.append("user-selected candidate")
            return (.high, reasons)
        }

        if rawRenderAgree {
            reasons.append("raw/render agree")
        }

        if rawRenderMismatch {
            reasons.append("raw/render mismatch")
        }

        if gap < 0.08 {
            reasons.append("top score gap is small")
        }
        if candidate.hasSevereNegativeSignal {
            reasons.append("candidate still has auxiliary-price context")
        }
        if missingPrimarySignal {
            reasons.append("missing title/buybox primary signal")
        }
        if candidate.sameAmountNodeCount > 6 {
            reasons.append("too many same-amount anchors")
        }
        if rawSource.isProtectionPage || !(rawSource.analysis?.hasMeaningfulContent ?? true) {
            reasons.append("raw HTML was weak")
        }

        if rawRenderAgree &&
            gap >= 0.18 &&
            candidate.hasPrimarySignal &&
            !candidate.hasSevereNegativeSignal &&
            (candidate.isVisible && candidate.isAboveTheFold) {
            return (.high, reasons)
        }

        if candidate.hasAuthoritativeSource &&
            !candidate.hasSevereNegativeSignal &&
            !rawRenderMismatch &&
            gap >= 0.14 {
            return (.medium, reasons)
        }

        if gap < 0.08 ||
            rawRenderMismatch ||
            candidate.hasSevereNegativeSignal ||
            missingPrimarySignal ||
            candidate.sameAmountNodeCount > 6 {
            return (.low, reasons)
        }

        return (.medium, reasons)
    }

    private func logResolution(
        _ report: PriceResolutionReport,
        requestURL: URL
    ) {
        let rawSummary = summarizeCandidates(report.rawAnalysis?.topCandidates ?? [])
        let renderedSummary = summarizeCandidates(report.renderedAnalysis?.topCandidates ?? [])
        let combinedSummary = summarizeCandidates(Array(report.combinedCandidates.prefix(5)))
        let final = report.finalCandidate

        Self.resolutionLogger.debug("Price resolution raw top candidates for \(requestURL.absoluteString, privacy: .public): \(rawSummary, privacy: .public)")
        Self.resolutionLogger.debug("Price resolution rendered top candidates for \(requestURL.absoluteString, privacy: .public): \(renderedSummary, privacy: .public)")
        Self.resolutionLogger.debug("Price resolution final candidates for \(requestURL.absoluteString, privacy: .public): \(combinedSummary, privacy: .public)")
        Self.resolutionLogger.debug("Price resolution selected \(final.candidate.amountKey, privacy: .public) score=\(final.score, privacy: .public) confidence=\(report.result.confidenceLevel.rawValue, privacy: .public) compare=\(report.comparisonReasons.joined(separator: " | "), privacy: .public) lowConfidenceReasons=\(report.confidenceReasons.joined(separator: " | "), privacy: .public)")
    }

    private func mergedRenderedCandidates(from snapshot: RenderedPageSnapshot) -> [PriceCandidate] {
        var merged: [PriceCandidate] = []
        var seen = Set<String>()

        func append(_ candidate: PriceCandidate) {
            let key = "\(candidate.amountKey)|\(candidate.anchorKey)"
            guard seen.insert(key).inserted else { return }
            merged.append(candidate)
        }

        if let selected = snapshot.selectedPriceCandidate {
            append(selected)
        }

        if !snapshot.visiblePriceCandidates.isEmpty {
            for candidate in snapshot.visiblePriceCandidates {
                append(candidate)
            }
        } else if let visiblePriceResult = snapshot.visiblePriceResult {
            append(PriceCandidateFactory.candidate(from: visiblePriceResult, origin: .renderedDOM))
        }

        return merged
    }

    private func candidatesMatch(_ lhs: PriceCandidate, _ rhs: PriceCandidate) -> Bool {
        lhs.amountKey == rhs.amountKey && lhs.anchorKey == rhs.anchorKey
    }

    private func summarizeCandidates(_ candidates: [ScoredPriceCandidate]) -> String {
        guard !candidates.isEmpty else { return "none" }
        return candidates.enumerated().map { index, scored in
            let candidate = scored.candidate
            let amount = NSDecimalNumber(decimal: candidate.amount).stringValue
            let reasons = scored.adoptionReasons.joined(separator: ",")
            let rejections = scored.rejectionReasons.joined(separator: ",")
            return "#\(index + 1) amount=\(amount) \(candidate.currency) source=\(candidate.sourceType.debugName) origin=\(candidate.origin.debugName) score=\(String(format: "%.3f", scored.score)) conf=\(String(format: "%.3f", candidate.confidence)) text=\(candidate.rawText) before=\(candidate.contextBefore) after=\(candidate.contextAfter) section=\(candidate.sectionType.rawValue) positive=\(candidate.positiveContextFlags.joined(separator: ",")) negative=\(candidate.negativeContextFlags.joined(separator: ",")) distanceToTitle=\(display(candidate.distanceToTitle)) distanceToBuy=\(display(candidate.distanceToBuyButton)) aboveFold=\(candidate.isAboveTheFold) visible=\(candidate.isVisible) ancestors=\(candidate.ancestorTokens.joined(separator: ",")) adopt=\(reasons) reject=\(rejections)"
        }.joined(separator: " || ")
    }

    private func display(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.1f", value)
    }

    private func requiresReview(for result: PriceResult) -> Bool {
        result.confidenceLevel == .low
    }

    private func lowConfidenceNote(for result: PriceResult) -> String {
        let priceString = NSDecimalNumber(decimal: result.price).stringValue
        return "low-confidence;price=\(priceString);currency=\(result.currency);method=\(result.extractMethod.rawValue)"
    }

    private func preferredTitle(customTitle: String?, extractedTitle: String?) -> String? {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? extractedTitle : trimmed
    }

    private func applyResolvedPrice(
        item: TrackingItem,
        domain: String,
        resolvedPage: ResolvedPagePrice,
        context: NSManagedObjectContext
    ) async {
        item.itemStatus = .ok
        item.itemPauseReason = nil
        item.failCountConsecutive = 0
        item.latestPriceDecimal = resolvedPage.priceResult.price
        item.latestCurrency = resolvedPage.priceResult.currency
        item.lastCheckedAt = Date()
        item.lastSuccessAt = Date()
        item.updatedAt = Date()
        item.itemLastErrorType = .none
        item.lastHttpStatus = Int16(resolvedPage.httpStatus)
        item.resolvedUrl = resolvedPage.resolvedUrlString

        if let imageUrl = resolvedPage.metadata.imageUrl, !imageUrl.isEmpty {
            item.imageUrl = imageUrl
        }
        if !resolvedPage.metadata.productIdHints.isEmpty {
            item.productIdHintsArray = resolvedPage.metadata.productIdHints
        }

        await throttler.recordSuccess(for: domain)

        let log = FetchLog.create(
            for: item,
            outcome: .success,
            httpStatus: Int16(resolvedPage.httpStatus),
            errorType: .none,
            extractMethod: resolvedPage.extractMethod,
            durationMs: resolvedPage.durationMs,
            note: FetchLog.makePriceNote(
                price: resolvedPage.priceResult.price,
                currency: resolvedPage.priceResult.currency
            ),
            context: context
        )
        item.addFetchLogAndRotate(log, context: context)

        let shouldSend = notificationService.shouldNotify(
            item: item,
            newPrice: resolvedPage.priceResult.price,
            currency: resolvedPage.priceResult.currency
        )
        if shouldSend {
            await notificationService.sendPriceDropNotification(
                for: item,
                newPrice: resolvedPage.priceResult.price,
                currency: resolvedPage.priceResult.currency
            )
        }

        PersistenceController.shared.save(context: context)
    }
}

private struct ResolvedPagePrice: Sendable {
    let priceResult: PriceResult
    let extractMethod: ExtractMethod
    let finalURL: URL
    let resolvedUrlString: String
    let metadata: PageMetadata
    let httpStatus: Int
    let durationMs: Int32
}

private struct SourceEvaluation {
    let analysis: PriceSourceAnalysis?
    let error: PriceCheckError?
    let isProtectionPage: Bool
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
