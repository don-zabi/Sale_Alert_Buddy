import Foundation
import CoreData
import Observation

/// Errors thrown by PriceCheckService.registerItem.
enum PriceCheckError: Error, LocalizedError {
    case invalidURL
    case duplicateURL(existingItem: TrackingItem)
    case priceNotFound
    case accessBlocked
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
        case .accessBlocked:
            return String(
                localized: "priceCheckError.accessBlocked",
                defaultValue: "This site showed a verification or anti-bot page, so the app could not read the product price.",
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
        visiblePriceResult: PriceResult? = nil
    ) async throws -> PreparedTrackingItemDraft {
        let preparedURL = try prepareNormalizedURL(
            from: URLNormalizer.normalize(originalUrlString) ?? pageURL.absoluteString
        )
        try throwIfDuplicate(url: preparedURL.normalizedUrl, context: context)

        do {
            let resolvedPage = try await resolveLoadedPage(
                pageHTML: pageHTML,
                pageURL: pageURL,
                preferRenderedVisiblePrice: true,
                visiblePriceResult: visiblePriceResult
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
        visiblePriceResult: PriceResult? = nil
    ) async throws -> ForegroundPriceCaptureResult {
        let resolvedPage = try await resolveLoadedPage(
            pageHTML: pageHTML,
            pageURL: pageURL,
            visiblePriceResult: visiblePriceResult
        )
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
            case .priceNotFound:
                errorType = .extractionFailed
            case .invalidURL, .duplicateURL:
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
        errorType: FetchErrorType = .extractionFailed
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
        visiblePriceResult: PriceResult? = nil
    ) async throws -> ResolvedPagePrice {
        let snapshotError: PriceCheckError?
        let capturedSnapshot = RenderedPageSnapshot(
            html: pageHTML,
            finalURL: pageURL,
            visiblePriceResult: visiblePriceResult
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
        let initialResolvedPrice: (result: PriceResult, method: ExtractMethod)?
        let initialError: PriceCheckError?

        do {
            initialResolvedPrice = try await resolvePriceOrThrow(
                from: html,
                requestURL: requestURL,
                allowURLFallback: allowURLFallback
            )
            initialError = nil
        } catch let error as PriceCheckError {
            initialResolvedPrice = nil
            initialError = error
        } catch {
            initialResolvedPrice = nil
            initialError = nil
        }

        let requiresRenderedFallback: Bool
        switch initialError {
        case .accessBlocked, .priceNotFound:
            requiresRenderedFallback = true
        case .invalidURL, .duplicateURL, .fetchFailed, nil:
            requiresRenderedFallback = false
        }

        let shouldAttemptRenderedConfirmation =
            renderedSnapshot != nil ||
            requiresRenderedFallback ||
            (preferRenderedVisiblePrice && initialResolvedPrice?.method != .siteAPI)

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

        var resolvedPrice = initialResolvedPrice
        var metadataHTML = html
        var finalURL = requestURL

        if let liveSnapshot {
            if !liveSnapshot.html.isEmpty {
                metadataHTML = liveSnapshot.html
                finalURL = liveSnapshot.finalURL
            }

            if let renderedVisiblePrice = liveSnapshot.visiblePriceResult {
                if let initialResolvedPrice,
                   shouldUseRenderedVisiblePrice(renderedVisiblePrice, over: initialResolvedPrice) {
                    resolvedPrice = (result: renderedVisiblePrice, method: renderedVisiblePrice.extractMethod)
                } else if resolvedPrice == nil {
                    resolvedPrice = (result: renderedVisiblePrice, method: renderedVisiblePrice.extractMethod)
                }
            }

            if resolvedPrice == nil,
               let renderedResolvedPrice = try await resolveRenderedSnapshotPrice(liveSnapshot) {
                resolvedPrice = renderedResolvedPrice
            }
        }

        guard let resolvedPrice else {
            throw initialError ?? PriceCheckError.priceNotFound
        }

        let metadata = metadataExtractor.extract(from: metadataHTML, requestUrl: finalURL)
        return ResolvedPagePrice(
            priceResult: resolvedPrice.result,
            extractMethod: resolvedPrice.method,
            finalURL: finalURL,
            resolvedUrlString: metadata.resolvedUrl ?? finalURL.absoluteString,
            metadata: metadata,
            httpStatus: httpStatus,
            durationMs: durationMs
        )
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
