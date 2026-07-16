import Testing
import Foundation
import CoreData
@testable import Sale_Alert_Buddy

@MainActor
private final class ForegroundMockRenderedPageLoader: RenderedPageLoading {
    let snapshot: RenderedPageSnapshot?

    init(snapshot: RenderedPageSnapshot?) {
        self.snapshot = snapshot
    }

    func load(url: URL) async -> RenderedPageSnapshot? {
        snapshot
    }
}

@Suite("Foreground Price Capture")
@MainActor
struct ForegroundPriceCaptureTests {

    private func makeService() -> PriceCheckService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return PriceCheckService(fetcher: HTMLFetcher(session: session))
    }

    @Test func prepareRegistrationReturnsDraftWithoutSavingItem() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.stub(
            urlContaining: "example.com/item",
            html: """
            <html>
            <head>
            <title>Example Product</title>
            <meta property="og:image" content="https://example.com/item.jpg">
            <script type="application/ld+json">
            {
              "@context":"https://schema.org",
              "@type":"Product",
              "offers":{"price":"1250","priceCurrency":"JPY"}
            }
            </script>
            </head>
            </html>
            """
        )

        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext
        let service = makeService()

        let draft = try await service.prepareRegistration(
            urlString: "https://example.com/item?utm_source=test",
            context: context
        )

        let count = try context.count(for: TrackingItem.fetchRequest())

        #expect(draft.priceResult.price == Decimal(1250))
        #expect(draft.priceResult.currency == "JPY")
        #expect(draft.metadata.title == "Example Product")
        #expect(count == 0)
    }

    @Test func finalizeRegistrationSavesPreparedDraft() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.stub(
            urlContaining: "example.com/item",
            html: """
            <html>
            <head>
            <title>Saved Product</title>
            <script type="application/ld+json">
            {
              "@context":"https://schema.org",
              "@type":"Product",
              "offers":{"price":"1737","priceCurrency":"JPY"}
            }
            </script>
            </head>
            </html>
            """
        )

        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext
        let service = makeService()

        let draft = try await service.prepareRegistration(
            urlString: "https://example.com/item",
            context: context
        )
        let item = try service.finalizeRegistration(
            from: draft,
            memo: "memo",
            tags: [],
            category: "dress",
            customTitle: "Custom Name",
            notificationConditionType: .amount,
            notificationConditionValue: 200,
            context: context
        )

        #expect(item.displayTitle == "Custom Name")
        #expect(item.latestPriceDecimal == Decimal(1737))
        #expect(item.memo == "memo")
        #expect(item.itemCategory == "dress")
        #expect(item.itemNotificationConditionType == .amount)
    }

    @Test func checkItemUsingLoadedPageAppliesSuccessfulPriceUpdate() async throws {
        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext
        let service = makeService()

        let item = TrackingItem.create(in: context)
        item.currentUrl = "https://example.com/item"
        item.domain = "example.com"
        item.baselinePriceDecimal = 2000
        item.baselineCurrency = "JPY"
        item.latestPriceDecimal = 2000
        item.latestCurrency = "JPY"
        item.itemStatus = .tempFailed
        item.itemLastErrorType = .accessBlocked

        let html = """
        <html>
        <head>
        <title>Recovered Product</title>
        <script type="application/ld+json">
        {
          "@context":"https://schema.org",
          "@type":"Product",
          "offers":{"price":"1500","priceCurrency":"JPY"}
        }
        </script>
        </head>
        </html>
        """

        let result = try await service.checkItemUsingLoadedPage(
            item,
            pageHTML: html,
            pageURL: URL(string: "https://example.com/item")!,
            context: context
        )

        #expect(result.priceResult.price == Decimal(1500))
        #expect(item.latestPriceDecimal == Decimal(1500))
        #expect(item.itemStatus == .ok)
        #expect(item.itemLastErrorType == .none)
        #expect(item.fetchLogsArray.first?.isSuccess == true)
    }

    @Test func checkItemUsingLoadedPageRequiresReviewWhenConfidenceIsLow() async throws {
        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext
        let service = makeService()

        let item = TrackingItem.create(in: context)
        item.currentUrl = "https://example.com/item"
        item.domain = "example.com"
        item.baselinePriceDecimal = 2000
        item.baselineCurrency = "JPY"
        item.latestPriceDecimal = 2000
        item.latestCurrency = "JPY"

        let html = """
        <html>
        <head>
        <script type="application/ld+json">
        {
          "@context":"https://schema.org",
          "@type":"Product",
          "offers":{"price":"5400","priceCurrency":"JPY"}
        }
        </script>
        </head>
        <body>
            <section class="related-items">
                <span class="price">¥5,400</span>
            </section>
        </body>
        </html>
        """

        await #expect(throws: PriceCheckError.self) {
            _ = try await service.checkItemUsingLoadedPage(
                item,
                pageHTML: html,
                pageURL: URL(string: "https://example.com/item")!,
                context: context,
                visiblePriceResult: PriceResult(
                    price: Decimal(3980),
                    currency: "JPY",
                    extractMethod: .renderedVisible,
                    confidence: 0.88
                )
            )
        }

        #expect(item.latestPriceDecimal == Decimal(2000))
        #expect(item.fetchLogsArray.isEmpty)
    }

    @Test func checkItemDoesNotAutoApplyLowConfidencePrice() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.stub(
            urlContaining: "example.com/mismatch",
            html: """
            <html>
            <head>
            <script type="application/ld+json">
            {
              "@context":"https://schema.org",
              "@type":"Product",
              "offers":{"@type":"Offer","price":"5400","priceCurrency":"JPY"}
            }
            </script>
            </head>
            <body>
            <section class="related-items">
                <span class="price">¥5,400</span>
            </section>
            </body>
            </html>
            """
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = PriceCheckService(
            fetcher: HTMLFetcher(session: session),
            renderedPageLoader: ForegroundMockRenderedPageLoader(
                snapshot: RenderedPageSnapshot(
                    html: "",
                    finalURL: URL(string: "https://example.com/mismatch")!,
                    visiblePriceResult: PriceResult(
                        price: Decimal(3980),
                        currency: "JPY",
                        extractMethod: .renderedVisible,
                        confidence: 0.88
                    )
                )
            )
        )

        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext

        let item = TrackingItem.create(in: context)
        item.currentUrl = "https://example.com/mismatch"
        item.domain = "example.com"
        item.baselinePriceDecimal = 2000
        item.baselineCurrency = "JPY"
        item.latestPriceDecimal = 2000
        item.latestCurrency = "JPY"
        item.itemStatus = .ok
        item.itemLastErrorType = .none

        await service.checkItem(item, context: context)

        #expect(item.latestPriceDecimal == Decimal(2000))
        #expect(item.itemStatus == .tempFailed)
        #expect(item.itemLastErrorType == .extractionFailed)
        #expect(item.fetchLogsArray.first?.isSuccess == false)
        #expect(item.fetchLogsArray.first?.note?.contains("low-confidence") == true)
    }
}
