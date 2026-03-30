import Testing
import Foundation
import CoreData
@testable import Sale_Alert_Buddy

@MainActor
private final class MockRenderedPageLoader: RenderedPageLoading {
    let snapshot: RenderedPageSnapshot?

    init(snapshot: RenderedPageSnapshot?) {
        self.snapshot = snapshot
    }

    func load(url: URL) async -> RenderedPageSnapshot? {
        snapshot
    }
}

@Suite("Rendered Page Fallback")
@MainActor
struct RenderedPageFallbackTests {

    @Test("prepareRegistration falls back to rendered HTML when fetched HTML has no price")
    func prepareRegistrationFallsBackToRenderedHTML() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.stub(
            urlContaining: "example.com/item",
            html: "<html><body><h1>Access Denied</h1></body></html>"
        )

        let renderedHTML = """
        <html><body>
        <table>
            <tr><th>価格：</th><td><strong>￥5,400</strong><span>（税込）</span></td></tr>
            <tr><th>通常価格：</th><td>￥10,800</td></tr>
        </table>
        </body></html>
        """

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = PriceCheckService(
            fetcher: HTMLFetcher(session: session),
            renderedPageLoader: MockRenderedPageLoader(
                snapshot: RenderedPageSnapshot(
                    html: renderedHTML,
                    finalURL: URL(string: "https://example.com/item")!,
                    visiblePriceResult: nil
                )
            )
        )

        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext

        let draft = try await service.prepareRegistration(
            urlString: "https://example.com/item",
            context: context
        )

        #expect(draft.priceResult.price == Decimal(5400))
        #expect(draft.priceResult.currency == "JPY")
    }

    @Test("prepareRegistration uses rendered visible price when HTML is blocked")
    func prepareRegistrationUsesRenderedVisiblePriceWhenHTMLIsBlocked() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.stub(
            urlContaining: "example.com/item",
            html: "<html><body><h1>Access Denied</h1></body></html>"
        )

        let service = PriceCheckService(
            fetcher: HTMLFetcher(session: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [MockURLProtocol.self]
                return URLSession(configuration: config)
            }()),
            renderedPageLoader: MockRenderedPageLoader(
                snapshot: RenderedPageSnapshot(
                    html: "",
                    finalURL: URL(string: "https://example.com/item")!,
                    visiblePriceResult: PriceResult(
                        price: Decimal(17_765),
                        currency: "JPY",
                        extractMethod: .renderedVisible,
                        confidence: 0.84
                    )
                )
            )
        )

        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext

        let draft = try await service.prepareRegistration(
            urlString: "https://example.com/item",
            context: context
        )

        #expect(draft.priceResult.price == Decimal(17_765))
        #expect(draft.priceResult.currency == "JPY")
        #expect(draft.extractMethod == .renderedVisible)
    }

    @Test("prepareRegistration prefers rendered visible price over stale structured price")
    func prepareRegistrationPrefersRenderedVisiblePriceOverStaleStructuredPrice() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.stub(
            urlContaining: "example.com/item",
            html: """
            <html>
            <head>
            <script type="application/ld+json">
            {
              "@context":"https://schema.org",
              "@type":"Product",
              "offers":{"@type":"Offer","price":"2052","priceCurrency":"JPY"}
            }
            </script>
            </head>
            <body>
            <div class="recommendations">
                <span>関連商品</span>
                <span class="price">￥2,052</span>
            </div>
            </body>
            </html>
            """
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = PriceCheckService(
            fetcher: HTMLFetcher(session: session),
            renderedPageLoader: MockRenderedPageLoader(
                snapshot: RenderedPageSnapshot(
                    html: "",
                    finalURL: URL(string: "https://example.com/item")!,
                    visiblePriceResult: PriceResult(
                        price: Decimal(758),
                        currency: "JPY",
                        extractMethod: .renderedVisible,
                        confidence: 0.84
                    )
                )
            )
        )

        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext

        let draft = try await service.prepareRegistration(
            urlString: "https://example.com/item",
            context: context
        )

        #expect(draft.priceResult.price == Decimal(758))
        #expect(draft.priceResult.currency == "JPY")
        #expect(draft.extractMethod == .renderedVisible)
    }

    @Test("prepareRegistrationFromLoadedPage prefers visible price from the captured browser page")
    func prepareRegistrationFromLoadedPagePrefersCapturedBrowserVisiblePrice() async throws {
        let service = PriceCheckService(
            renderedPageLoader: MockRenderedPageLoader(
                snapshot: RenderedPageSnapshot(
                    html: "",
                    finalURL: URL(string: "https://example.com/item")!,
                    visiblePriceResult: PriceResult(
                        price: Decimal(2_052),
                        currency: "JPY",
                        extractMethod: .renderedVisible,
                        confidence: 0.84
                    )
                )
            )
        )

        let store = PersistenceController(inMemory: true)
        let context = store.container.viewContext

        let draft = try await service.prepareRegistrationFromLoadedPage(
            originalUrlString: "https://example.com/item",
            pageHTML: """
            <html>
            <head>
            <script type="application/ld+json">
            {
              "@context":"https://schema.org",
              "@type":"Product",
              "offers":{"@type":"Offer","price":"2052","priceCurrency":"JPY"}
            }
            </script>
            </head>
            <body>
            <div class="buy-box">
                <span class="price">￥2,052</span>
            </div>
            </body>
            </html>
            """,
            pageURL: URL(string: "https://example.com/item")!,
            context: context,
            visiblePriceResult: PriceResult(
                price: Decimal(1_637),
                currency: "JPY",
                extractMethod: .renderedVisible,
                confidence: 0.86
            )
        )

        #expect(draft.priceResult.price == Decimal(1_637))
        #expect(draft.priceResult.currency == "JPY")
        #expect(draft.extractMethod == .renderedVisible)
    }
}
