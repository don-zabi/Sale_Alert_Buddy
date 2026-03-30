import Testing
import Foundation
import SwiftSoup
@testable import Sale_Alert_Buddy

@Suite("Contextual Price Extraction")
struct ContextualPriceExtractionTests {

    @Test("labeled rows prefer displayed price over list price and points")
    func extractsDisplayedPriceFromLabeledRows() throws {
        let html = """
        <html><body>
        <table>
            <tr><th>希望小売価格：</th><td>￥2,052</td></tr>
            <tr>
                <th>価格：</th>
                <td>
                    <strong class="price-main">￥758</strong>
                    <span>（税込）</span>
                    <span>【希望小売価格より￥1,294の値引き】</span>
                </td>
            </tr>
            <tr><th>ゴールドポイント：</th><td>76 ゴールドポイント還元</td></tr>
        </table>
        </body></html>
        """

        let document = try SwiftSoup.parse(html)
        let results = ContextualPriceExtractor().extract(from: document)

        #expect(results.first?.price == Decimal(758))
        #expect(results.first?.currency == "JPY")
        #expect(results.first?.extractMethod == .htmlContext)
    }

    @Test("pipeline prefers current price shared by JSON and DOM context")
    func pipelinePrefersConsensusCurrentPrice() {
        let html = """
        <html>
        <body>
        <script>
        window.__ITEM__ = {
            "currentPrice": 758,
            "usualPrice": 2052,
            "priceLabels": {
                "price": "￥758",
                "usual": "￥2,052"
            }
        };
        </script>
        <table>
            <tr><th>希望小売価格：</th><td>￥2,052</td></tr>
            <tr><th>価格：</th><td><strong class="price-main">￥758</strong><span>（税込）</span></td></tr>
            <tr><th>ゴールドポイント：</th><td>76 ゴールドポイント還元</td></tr>
        </table>
        </body>
        </html>
        """

        let result = PriceExtractionPipeline().extract(from: html)

        #expect(result?.result.price == Decimal(758))
        #expect(result?.result.currency == "JPY")
    }

    @Test("pipeline prefers visible current price over stale schema price")
    func pipelinePrefersVisibleCurrentPriceOverStaleSchema() {
        let html = """
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
        <table>
            <tr><th>希望小売価格：</th><td>￥2,052</td></tr>
            <tr><th>価格：</th><td><strong class="price-main">￥758</strong><span>（税込）</span></td></tr>
            <tr><th>ゴールドポイント：</th><td>76 ゴールドポイント還元</td></tr>
        </table>
        </body>
        </html>
        """

        let result = PriceExtractionPipeline().extract(from: html)

        #expect(result?.result.price == Decimal(758))
        #expect(result?.result.currency == "JPY")
    }

    @Test("pipeline prefers visible sale price over meta reference price")
    func pipelinePrefersVisibleSalePriceOverMetaReferencePrice() {
        let html = """
        <html>
        <head>
        <meta property="product:price:amount" content="2052">
        <meta property="product:price:currency" content="JPY">
        </head>
        <body>
        <div class="product-summary">
            <div class="reference-price">通常価格: ￥2,052</div>
            <div class="current-price-block">
                <span class="label">価格</span>
                <span class="sale-price">￥758</span>
                <span class="tax-note">税込</span>
            </div>
            <div class="point-return">76ポイント還元</div>
        </div>
        </body>
        </html>
        """

        let result = PriceExtractionPipeline().extract(from: html)

        #expect(result?.result.price == Decimal(758))
        #expect(result?.result.currency == "JPY")
    }

    @Test("pipeline prefers visible current price over repeated structured reference prices")
    func pipelinePrefersVisibleCurrentPriceOverRepeatedStructuredReferencePrices() {
        let html = """
        <html>
        <head>
        <meta property="product:price:amount" content="2052">
        <meta property="product:price:currency" content="JPY">
        <script type="application/ld+json">
        {
          "@context":"https://schema.org",
          "@type":"Product",
          "offers":{"@type":"Offer","price":"2052","priceCurrency":"JPY"}
        }
        </script>
        <script type="application/json">
        {
          "product": {
            "regularPrice": 2052,
            "currency": "JPY"
          }
        }
        </script>
        </head>
        <body>
        <div class="product-summary">
            <div class="reference-price">通常価格: ￥2,052</div>
            <div class="current-price-block">
                <span class="label">販売価格</span>
                <span class="sale-price">￥758</span>
                <span class="tax-note">税込</span>
            </div>
            <div class="point-return">76ポイント還元</div>
        </div>
        </body>
        </html>
        """

        let result = PriceExtractionPipeline().extract(from: html)

        #expect(result?.result.price == Decimal(758))
        #expect(result?.result.currency == "JPY")
    }

    @Test("pipeline prefers product price over recommendation section price")
    func pipelinePrefersProductPriceOverRecommendationSectionPrice() {
        let html = """
        <html>
        <body>
        <main class="product-detail">
            <section class="product-summary">
                <div class="price-block">
                    <span class="label">販売価格</span>
                    <span class="price-main">￥795</span>
                    <span class="tax-note">税込</span>
                </div>
            </section>
        </main>
        <section class="recommendation ranking review">
            <h2>おすすめ商品</h2>
            <div class="recommendation-card">
                <span class="label">価格</span>
                <span class="price">￥904</span>
            </div>
        </section>
        </body>
        </html>
        """

        let result = PriceExtractionPipeline().extract(from: html)

        #expect(result?.result.price == Decimal(795))
        #expect(result?.result.currency == "JPY")
    }
}
