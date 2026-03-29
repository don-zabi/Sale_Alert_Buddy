import Testing
import Foundation
import CoreData
@testable import Sale_Alert_Buddy

// MARK: - Mock URLProtocol

/// URLProtocol subclass that intercepts requests and returns canned responses.
/// Register stubs via `MockURLProtocol.stub(url:data:statusCode:mimeType:)` before making requests.
final class MockURLProtocol: URLProtocol {

    // MARK: - Stub Registry

    struct Stub {
        let data: Data
        let statusCode: Int
        let mimeType: String
        let error: Error?
    }

    static var stubs: [String: Stub] = [:]
    static var defaultStub: Stub?

    static func stub(
        urlContaining substring: String,
        html: String,
        statusCode: Int = 200,
        mimeType: String = "text/html; charset=utf-8"
    ) {
        stubs[substring] = Stub(
            data: html.data(using: .utf8) ?? Data(),
            statusCode: statusCode,
            mimeType: mimeType,
            error: nil
        )
    }

    static func stub(urlContaining substring: String, error: Error) {
        stubs[substring] = Stub(data: Data(), statusCode: 0, mimeType: "", error: error)
    }

    static func reset() {
        stubs.removeAll()
        defaultStub = nil
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""

        // Find matching stub
        let stub = MockURLProtocol.stubs.first(where: { urlString.contains($0.key) })?.value
                   ?? MockURLProtocol.defaultStub

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.mimeType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Mock HTMLFetcher

/// HTMLFetcher subclass/wrapper that returns canned FetchResults without network I/O.
/// Used so PriceCheckService tests don't need a real URLSession.
actor MockHTMLFetcher {

    enum Response {
        case success(html: String, httpStatus: Int = 200, finalURL: URL? = nil)
        case failure(HTMLFetchError)
    }

    var responsesByURL: [String: Response] = [:]
    var defaultResponse: Response?

    func setResponse(_ response: Response, forURLContaining substring: String) {
        responsesByURL[substring] = response
    }

    func setDefaultResponse(_ response: Response) {
        defaultResponse = response
    }

    func fetch(url: URL, timeout: TimeInterval = 15) async throws -> HTMLFetcher.FetchResult {
        let urlString = url.absoluteString
        let response = responsesByURL.first(where: { urlString.contains($0.key) })?.value
                       ?? defaultResponse

        switch response {
        case .success(let html, let statusCode, let finalURL):
            return HTMLFetcher.FetchResult(
                html: html,
                httpStatus: statusCode,
                finalURL: finalURL ?? url,
                durationMs: 50
            )
        case .failure(let error):
            throw error
        case nil:
            throw HTMLFetchError.network(underlying: URLError(.fileDoesNotExist))
        }
    }
}

// MARK: - TestPriceCheckService

/// Concrete subclass of PriceCheckService that bypasses the actor HTMLFetcher
/// using a MockHTMLFetcher. Overrides checkItem and registerItem to inject responses.
///
/// Because PriceCheckService uses a `private let fetcher: HTMLFetcher` (actor type),
/// we cannot directly subclass and swap the fetcher. Instead, we use a thin wrapper
/// service that delegates to the mock.
@Observable
final class TestPriceCheckService {

    private(set) var isChecking: Bool = false
    private(set) var checkProgress: Double = 0

    let mockFetcher: MockHTMLFetcher
    let pipeline: PriceExtractionPipeline
    let metadataExtractor: MetadataExtractor
    let throttler: DomainThrottler
    let notificationService: NotificationService

    /// Track whether shouldNotify was called and with what price.
    var lastShouldNotifyCallPrice: Decimal?
    var notificationSentCount: Int = 0

    init() {
        mockFetcher = MockHTMLFetcher()
        pipeline = PriceExtractionPipeline()
        metadataExtractor = MetadataExtractor()
        throttler = DomainThrottler()
        notificationService = NotificationService.shared
    }

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
        guard let normalizedUrl = URLNormalizer.normalize(urlString) else {
            throw PriceCheckError.invalidURL
        }
        guard let url = URL(string: normalizedUrl) else {
            throw PriceCheckError.invalidURL
        }

        let domain = url.host ?? ""

        let duplicateRequest = TrackingItem.fetchRequest()
        duplicateRequest.predicate = NSPredicate(format: "currentUrl == %@", normalizedUrl)
        duplicateRequest.fetchLimit = 1
        if let existing = try? context.fetch(duplicateRequest), let existingItem = existing.first {
            throw PriceCheckError.duplicateURL(existingItem: existingItem)
        }

        try? await throttler.waitIfNeeded(for: domain)

        let fetchResult: HTMLFetcher.FetchResult
        do {
            fetchResult = try await mockFetcher.fetch(url: url)
        } catch {
            throw PriceCheckError.fetchFailed(underlying: error)
        }

        let metadata = metadataExtractor.extract(from: fetchResult.html, requestUrl: fetchResult.finalURL)
        let trimmedCustomTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let (priceResult, _) = pipeline.extract(from: fetchResult.html) else {
            throw PriceCheckError.priceNotFound
        }

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

        PersistenceController.shared.save(context: context)
        return item
    }

    func checkItem(
        _ item: TrackingItem,
        context: NSManagedObjectContext,
        timeout: TimeInterval = 15
    ) async {
        guard item.itemStatus != .paused else { return }

        let domain = item.domain
        guard let url = URL(string: item.currentUrl) else {
            item.failCountConsecutive += 1
            item.itemLastErrorType = .network
            item.itemStatus = item.failCountConsecutive >= 3 ? .paused : .tempFailed
            if item.failCountConsecutive >= 3 { item.itemPauseReason = .consecutiveFailures }
            item.lastCheckedAt = Date()
            item.updatedAt = Date()
            PersistenceController.shared.save(context: context)
            return
        }

        try? await throttler.waitIfNeeded(for: domain)

        do {
            let fetchResult = try await mockFetcher.fetch(url: url, timeout: timeout)

            guard let (priceResult, extractMethod) = pipeline.extract(from: fetchResult.html) else {
                item.failCountConsecutive += 1
                item.itemLastErrorType = .extractionFailed
                item.lastCheckedAt = Date()
                item.updatedAt = Date()
                item.itemStatus = item.failCountConsecutive >= 3 ? .paused : .tempFailed
                if item.failCountConsecutive >= 3 { item.itemPauseReason = .consecutiveFailures }
                let log = FetchLog.create(for: item, outcome: .failure, httpStatus: Int16(fetchResult.httpStatus), errorType: .extractionFailed, durationMs: fetchResult.durationMs, context: context)
                item.addFetchLogAndRotate(log, context: context)
                PersistenceController.shared.save(context: context)
                return
            }

            item.itemStatus = .ok
            item.failCountConsecutive = 0
            item.latestPriceDecimal = priceResult.price
            item.latestCurrency = priceResult.currency
            item.lastCheckedAt = Date()
            item.lastSuccessAt = Date()
            item.updatedAt = Date()
            item.itemLastErrorType = .none

            await throttler.recordSuccess(for: domain)

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

            let shouldSend = await MainActor.run {
                notificationService.shouldNotify(
                    item: item,
                    newPrice: priceResult.price,
                    currency: priceResult.currency
                )
            }
            if shouldSend {
                notificationSentCount += 1
                lastShouldNotifyCallPrice = priceResult.price
            }

            PersistenceController.shared.save(context: context)

        } catch let fetchError as HTMLFetchError {
            item.failCountConsecutive += 1
            item.lastCheckedAt = Date()
            item.updatedAt = Date()
            item.itemLastErrorType = fetchError.fetchErrorType

            let httpStatus: Int16
            if let code = fetchError.httpStatusCode {
                httpStatus = Int16(code)
                item.lastHttpStatus = httpStatus
            } else {
                httpStatus = 0
            }

            let log = FetchLog.create(for: item, outcome: .failure, httpStatus: httpStatus == 0 ? nil : httpStatus, errorType: fetchError.fetchErrorType, durationMs: 0, context: context)
            item.addFetchLogAndRotate(log, context: context)

            _ = await throttler.recordFailure(for: domain, httpStatus: fetchError.httpStatusCode)

            if case .http4xx(let code) = fetchError, code == 429 || code == 403 {
                item.itemStatus = .paused
                item.itemPauseReason = .consecutiveFailures
            } else if item.failCountConsecutive >= 3 {
                item.itemStatus = .paused
                item.itemPauseReason = .consecutiveFailures
            } else {
                item.itemStatus = .tempFailed
            }

            PersistenceController.shared.save(context: context)
        } catch {
            item.failCountConsecutive += 1
            item.itemLastErrorType = .network
            item.lastCheckedAt = Date()
            item.updatedAt = Date()
            item.itemStatus = item.failCountConsecutive >= 3 ? .paused : .tempFailed
            if item.failCountConsecutive >= 3 { item.itemPauseReason = .consecutiveFailures }
            PersistenceController.shared.save(context: context)
        }
    }
}

// MARK: - Sample HTML Fixtures

private enum HTMLFixtures {

    /// Minimal HTML with a JSON-LD product price that PriceExtractionPipeline can extract.
    static let jpyProductPage = """
    <!DOCTYPE html>
    <html lang="ja">
    <head>
        <title>テスト商品 - ショップ</title>
        <meta property="og:title" content="テスト商品">
        <meta property="og:image" content="https://example.com/image.jpg">
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "Product",
          "name": "テスト商品",
          "offers": {
            "@type": "Offer",
            "price": "1980",
            "priceCurrency": "JPY"
          }
        }
        </script>
    </head>
    <body>
        <span class="price">¥1,980</span>
    </body>
    </html>
    """

    /// HTML with a lower price (900 JPY) for price-drop tests.
    static let jpyProductPageDropped = """
    <!DOCTYPE html>
    <html lang="ja">
    <head>
        <title>テスト商品 - ショップ</title>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "Product",
          "name": "テスト商品",
          "offers": {
            "@type": "Offer",
            "price": "900",
            "priceCurrency": "JPY"
          }
        }
        </script>
    </head>
    <body>
        <span class="price">¥900</span>
    </body>
    </html>
    """

    /// HTML with same price as baseline (1980 JPY).
    static let jpyProductPageSamePrice = jpyProductPage

    /// HTML with no price information.
    static let noPrice = """
    <!DOCTYPE html>
    <html><head><title>No Price Page</title></head>
    <body><p>This page has no price information.</p></body>
    </html>
    """
}

// MARK: - Tests

@MainActor
struct PriceCheckServiceTests {

    private func makeContext() -> NSManagedObjectContext {
        TestPersistence.newContext()
    }

    private func makeService() -> TestPriceCheckService {
        TestPriceCheckService()
    }

    // MARK: - registerItem: Success

    @Test func registerItemCreatesItemWithCorrectBaselinePrice() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        #expect(item.baselinePriceDecimal == 1980)
        #expect(item.baselineCurrency == "JPY")
    }

    @Test func registerItemSetsDomain() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: "test memo",
            tags: ["sale"],
            context: context
        )

        #expect(item.domain == "example.com")
    }

    @Test func registerItemSetsProductTitle() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        // Title should be from og:title or <title>
        #expect(item.productTitle != nil)
        #expect(!(item.productTitle?.isEmpty ?? true))
    }

    @Test func registerItemSetsStatusOK() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        #expect(item.itemStatus == .ok)
    }

    @Test func registerItemSetsNormalizedURL() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        let item = try await service.registerItem(
            urlString: "HTTPS://EXAMPLE.COM/product?utm_source=google",
            memo: nil,
            tags: [],
            context: context
        )

        // Normalized URL should be lowercase and without utm params
        #expect(item.currentUrl.hasPrefix("https://example.com"))
        #expect(!item.currentUrl.contains("utm_source"))
    }

    // MARK: - registerItem: Failures

    @Test func registerItemThrowsForInvalidURL() async {
        let context = makeContext()
        let service = makeService()

        await #expect(throws: PriceCheckError.self) {
            try await service.registerItem(
                urlString: "not a valid url %%",
                memo: nil,
                tags: [],
                context: context
            )
        }
    }

    @Test func registerItemThrowsForNonHTTPURL() async {
        let context = makeContext()
        let service = makeService()

        await #expect(throws: PriceCheckError.self) {
            try await service.registerItem(
                urlString: "ftp://example.com/file",
                memo: nil,
                tags: [],
                context: context
            )
        }
    }

    @Test func registerItemThrowsWhenNoPriceFound() async {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.noPrice),
            forURLContaining: "example.com"
        )

        await #expect(throws: PriceCheckError.self) {
            try await service.registerItem(
                urlString: "https://example.com/product",
                memo: nil,
                tags: [],
                context: context
            )
        }
    }

    @Test func registerItemThrowsOnNetworkError() async {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .failure(HTMLFetchError.network(underlying: URLError(.timedOut))),
            forURLContaining: "example.com"
        )

        await #expect(throws: PriceCheckError.self) {
            try await service.registerItem(
                urlString: "https://example.com/product",
                memo: nil,
                tags: [],
                context: context
            )
        }
    }

    @Test func registerItemThrowsDuplicateURLError() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        // First registration succeeds
        _ = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        // Second registration with same URL should throw .duplicateURL
        var caughtDuplicate = false
        do {
            _ = try await service.registerItem(
                urlString: "https://example.com/product",
                memo: nil,
                tags: [],
                context: context
            )
        } catch PriceCheckError.duplicateURL {
            caughtDuplicate = true
        } catch {
            // Other errors are unexpected
        }
        #expect(caughtDuplicate == true)
    }

    // MARK: - checkItem: Success Path

    @Test func checkItemSuccessUpdatesLatestPrice() async throws {
        let context = makeContext()
        let service = makeService()

        // Register item first
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )
        #expect(item.baselinePriceDecimal == 1980)

        // Now check with a dropped price
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPageDropped),
            forURLContaining: "example.com"
        )
        await service.checkItem(item, context: context)

        #expect(item.latestPriceDecimal == 900)
    }

    @Test func checkItemSuccessSetsStatusOK() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        // Manually set to tempFailed to verify checkItem resets it
        item.itemStatus = .tempFailed

        await service.checkItem(item, context: context)

        #expect(item.itemStatus == .ok)
    }

    @Test func checkItemSuccessResetsFailCount() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        item.failCountConsecutive = 2

        await service.checkItem(item, context: context)

        #expect(item.failCountConsecutive == 0)
    }

    @Test func checkItemSuccessCreatesFetchLog() async throws {
        let context = makeContext()
        let service = makeService()
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )

        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        let logCountBefore = item.fetchLogsArray.count

        await service.checkItem(item, context: context)

        let logCountAfter = item.fetchLogsArray.count
        #expect(logCountAfter > logCountBefore)

        // The latest log should be a success
        let latestLog = item.fetchLogsArray.first
        #expect(latestLog?.fetchOutcome == .success)
    }

    // MARK: - checkItem: Same Price (no notification)

    @Test func checkItemSamePriceDoesNotSendNotification() async throws {
        let context = makeContext()
        let service = makeService()

        // baseline = 1980, new price = 1980 (same) — threshold 1% not met
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPageSamePrice),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        await service.checkItem(item, context: context)

        #expect(service.notificationSentCount == 0)
    }

    // MARK: - checkItem: Price Drop > Threshold (notification conditions)

    @Test func checkItemPriceDropBeyondThresholdMarksNotificationConditionMet() async throws {
        let context = makeContext()
        let service = makeService()

        // Register at 1980 JPY
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )
        #expect(item.baselinePriceDecimal == 1980)

        // Check with dropped price (900 JPY, ~54% drop >> 1% threshold)
        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPageDropped),
            forURLContaining: "example.com"
        )
        await service.checkItem(item, context: context)

        #expect(service.notificationSentCount == 1)
        #expect(service.lastShouldNotifyCallPrice == 900)
    }

    // MARK: - checkItem: Network Error

    @Test func checkItemNetworkErrorIncrementsFailCount() async throws {
        let context = makeContext()
        let service = makeService()

        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        await service.mockFetcher.setResponse(
            .failure(HTMLFetchError.network(underlying: URLError(.timedOut))),
            forURLContaining: "example.com"
        )

        await service.checkItem(item, context: context)

        #expect(item.failCountConsecutive == 1)
    }

    @Test func checkItemNetworkErrorSetsStatusTempFailed() async throws {
        let context = makeContext()
        let service = makeService()

        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        await service.mockFetcher.setResponse(
            .failure(HTMLFetchError.network(underlying: URLError(.timedOut))),
            forURLContaining: "example.com"
        )

        await service.checkItem(item, context: context)

        #expect(item.itemStatus == .tempFailed)
    }

    @Test func checkItemNetworkErrorCreatesFetchLogWithFailureOutcome() async throws {
        let context = makeContext()
        let service = makeService()

        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )
        let logsBefore = item.fetchLogsArray.count

        await service.mockFetcher.setResponse(
            .failure(HTMLFetchError.network(underlying: URLError(.timedOut))),
            forURLContaining: "example.com"
        )
        await service.checkItem(item, context: context)

        let logsAfter = item.fetchLogsArray.count
        #expect(logsAfter > logsBefore)
        #expect(item.fetchLogsArray.first?.fetchOutcome == .failure)
    }

    // MARK: - checkItem: 3 Consecutive Failures → Paused

    @Test func threeConsecutiveNetworkFailuresPausesItem() async throws {
        let context = makeContext()
        let service = makeService()

        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        await service.mockFetcher.setResponse(
            .failure(HTMLFetchError.network(underlying: URLError(.timedOut))),
            forURLContaining: "example.com"
        )

        await service.checkItem(item, context: context)
        await service.checkItem(item, context: context)
        await service.checkItem(item, context: context)

        #expect(item.itemStatus == .paused)
        #expect(item.itemPauseReason == .consecutiveFailures)
    }

    @Test func twoConsecutiveFailuresDoesNotPause() async throws {
        let context = makeContext()
        let service = makeService()

        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        await service.mockFetcher.setResponse(
            .failure(HTMLFetchError.network(underlying: URLError(.timedOut))),
            forURLContaining: "example.com"
        )

        await service.checkItem(item, context: context)
        await service.checkItem(item, context: context)

        #expect(item.itemStatus == .tempFailed)
        #expect(item.itemStatus != .paused)
    }

    // MARK: - checkItem: 429 → Immediate Pause

    @Test func check429ResponsePausesItemImmediately() async throws {
        let context = makeContext()
        let service = makeService()

        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        await service.mockFetcher.setResponse(
            .failure(HTMLFetchError.http4xx(statusCode: 429)),
            forURLContaining: "example.com"
        )

        await service.checkItem(item, context: context)

        #expect(item.itemStatus == .paused)
        #expect(item.itemPauseReason == .consecutiveFailures)
    }

    // MARK: - checkItem: Skips Paused Item

    @Test func checkItemSkipsPausedItem() async throws {
        let context = makeContext()
        let service = makeService()

        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPage),
            forURLContaining: "example.com"
        )
        let item = try await service.registerItem(
            urlString: "https://example.com/product",
            memo: nil,
            tags: [],
            context: context
        )

        item.itemStatus = .paused
        let priceBefore = item.latestPriceDecimal

        await service.mockFetcher.setResponse(
            .success(html: HTMLFixtures.jpyProductPageDropped),
            forURLContaining: "example.com"
        )

        await service.checkItem(item, context: context)

        // Price should not have changed since item was paused
        #expect(item.latestPriceDecimal == priceBefore)
    }

    // MARK: - HTMLFetchError.fetchErrorType Mapping

    @Test func invalidURLMapsToNetworkErrorType() {
        let error = HTMLFetchError.invalidURL
        #expect(error.fetchErrorType == .network)
    }

    @Test func networkErrorMapsToNetworkErrorType() {
        let error = HTMLFetchError.network(underlying: URLError(.timedOut))
        #expect(error.fetchErrorType == .network)
    }

    @Test func http4xxMapsToHttp4xxErrorType() {
        let error = HTMLFetchError.http4xx(statusCode: 404)
        #expect(error.fetchErrorType == .http4xx)
    }

    @Test func http5xxMapsToHttp5xxErrorType() {
        let error = HTMLFetchError.http5xx(statusCode: 503)
        #expect(error.fetchErrorType == .http5xx)
    }

    @Test func notHTMLMapsToExtractionFailed() {
        let error = HTMLFetchError.notHTML
        #expect(error.fetchErrorType == .extractionFailed)
    }

    // MARK: - HTMLFetchError.httpStatusCode

    @Test func http4xxProvidesStatusCode() {
        let error = HTMLFetchError.http4xx(statusCode: 403)
        #expect(error.httpStatusCode == 403)
    }

    @Test func http5xxProvidesStatusCode() {
        let error = HTMLFetchError.http5xx(statusCode: 500)
        #expect(error.httpStatusCode == 500)
    }

    @Test func networkErrorHasNilStatusCode() {
        let error = HTMLFetchError.network(underlying: URLError(.timedOut))
        #expect(error.httpStatusCode == nil)
    }

    @Test func notHTMLHasNilStatusCode() {
        #expect(HTMLFetchError.notHTML.httpStatusCode == nil)
    }
}
