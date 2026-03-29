import Testing
import Foundation
@testable import Sale_Alert_Buddy

@Suite("SiteSpecificPriceResolver")
@MainActor
struct SiteSpecificPriceResolverTests {

    @Test func udemyResolverPrefersCoursePurchasePriceOverSubscriptionPrice() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let apiResponse = """
        {
          "buy_button": {
            "button": {
              "payment_data": {
                "purchasePrice": {
                  "amount": 27800.0,
                  "currency": "JPY",
                  "price_string": "￥27,800"
                }
              }
            }
          },
          "purchase": {
            "data": {
              "pricing_result": {
                "price": {
                  "amount": 27800.0,
                  "currency": "JPY",
                  "price_string": "￥27,800"
                }
              }
            }
          },
          "purchase_tabs_context": {
            "subscriptionContext": {
              "title_extension": "¥27,500.00/月"
            },
            "selectedPurchaseOption": "subscription"
          }
        }
        """

        MockURLProtocol.stub(
            urlContaining: "/api-2.0/course-landing-components/6132321/me/",
            html: apiResponse,
            mimeType: "application/json"
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let resolver = SiteSpecificPriceResolver(session: session)

        let html = """
        <html><body>
        <script>window.__TEST__ = "courseId=6132321";</script>
        </body></html>
        """

        let result = await resolver.resolve(
            for: URL(string: "https://www.udemy.com/course/google-gemini/")!,
            html: html,
            allowURLFallback: false
        )

        #expect(result != nil)
        #expect(result?.result.price == Decimal(27800))
        #expect(result?.result.currency == "JPY")
        #expect(result?.method == .siteAPI)
        #expect(MockURLProtocol.lastRequest?.url?.absoluteString.contains("/course-landing-components/6132321/me/") == true)
    }

    @Test func udemyResolverCanExtractCourseIDFromImageURL() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let apiResponse = """
        {
          "price_text": {
            "data": {
              "pricing_result": {
                "price": {
                  "amount": 19800.0,
                  "currency": "JPY",
                  "price_string": "￥19,800"
                }
              }
            }
          }
        }
        """

        MockURLProtocol.stub(
            urlContaining: "/api-2.0/course-landing-components/6132321/me/",
            html: apiResponse,
            mimeType: "application/json"
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let resolver = SiteSpecificPriceResolver(session: session)

        let html = """
        <html><body>
        <img src="https://img-c.udemycdn.com/course/480x270/6132321_e113_2.jpg">
        </body></html>
        """

        let result = await resolver.resolve(
            for: URL(string: "https://www.udemy.com/course/google-gemini/")!,
            html: html,
            allowURLFallback: false
        )

        #expect(result != nil)
        #expect(result?.result.price == Decimal(19800))
        #expect(result?.result.currency == "JPY")
    }

    @Test func temuResolverDecodesProtectedSharePriceOnlyWhenFallbackAllowed() async {
        let resolver = SiteSpecificPriceResolver()
        let html = """
        <html><body>
        <script src="https://static.kwcdn.com/upload-static/assets/chl/js/abc.js"></script>
        <div>challenge</div>
        </body></html>
        """
        let url = URL(string: "https://www.temu.com/jp/item-g-601105326007423.html?_oak_rec_ext_1=MTI1")!

        let blockedResult = await resolver.resolve(
            for: url,
            html: html,
            allowURLFallback: false
        )
        #expect(blockedResult == nil)

        let fallbackResult = await resolver.resolve(
            for: url,
            html: html,
            allowURLFallback: true
        )

        #expect(fallbackResult != nil)
        #expect(fallbackResult?.result.price == Decimal(125))
        #expect(fallbackResult?.result.currency == "JPY")
        #expect(fallbackResult?.method == .siteAPI)
    }

    @Test func sheinResolverUsesBffSalePriceWhenAvailable() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let apiResponse = """
        {
          "info": {
            "products": {
              "396123668": {
                "salePrice": {
                  "amount": 1737,
                  "amountWithSymbol": "¥1,737"
                },
                "retailPrice": {
                  "amount": 2999,
                  "amountWithSymbol": "¥2,999"
                }
              }
            }
          }
        }
        """

        MockURLProtocol.stub(
            urlContaining: "/bff-api/product/get_goods_detail_realtime_data",
            html: apiResponse,
            mimeType: "application/json"
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let resolver = SiteSpecificPriceResolver(session: session)

        let html = """
        <html><body>
        <script>
        var _constants = {"csrf_token":"test-token"}
        </script>
        </body></html>
        """

        let result = await resolver.resolve(
            for: URL(string: "https://m.shein.com/jp/FRIFUL-Women-s-Casual-Vacation-All-Over-Print-Dress-Sundress-p-396123668.html?mallCode=1&detailBusinessFrom=0-2")!,
            html: html,
            allowURLFallback: false
        )

        #expect(result != nil)
        #expect(result?.result.price == Decimal(1737))
        #expect(result?.result.currency == "JPY")
        #expect(result?.method == .siteAPI)
        #expect(MockURLProtocol.lastRequest?.url?.absoluteString.contains("/bff-api/product/get_goods_detail_realtime_data") == true)
        #expect(MockURLProtocol.lastRequest?.url?.absoluteString.contains("goods_id=396123668") == true)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-CSRF-Token") == "test-token")
    }
}
