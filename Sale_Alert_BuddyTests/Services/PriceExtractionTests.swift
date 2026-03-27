// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Testing
import Foundation
import SwiftSoup
@testable import Sale_Alert_Buddy

// MARK: - PriceValidator Tests

struct PriceValidatorTests {

    @Test func rejectsZeroPrice() {
        let result = PriceResult(price: 0, currency: "JPY", extractMethod: .schemaOrg, confidence: 0.95)
        #expect(PriceValidator.validate(result) == false)
    }

    @Test func rejectsEmptyCurrency() {
        let result = PriceResult(price: 1000, currency: "", extractMethod: .schemaOrg, confidence: 0.95)
        #expect(PriceValidator.validate(result) == false)
    }

    @Test func rejectsJPYAbove10Million() {
        let result = PriceResult(price: 10_000_001, currency: "JPY", extractMethod: .schemaOrg, confidence: 0.95)
        #expect(PriceValidator.validate(result) == false)
    }

    @Test func acceptsJPYAt10Million() {
        let result = PriceResult(price: 10_000_000, currency: "JPY", extractMethod: .schemaOrg, confidence: 0.95)
        #expect(PriceValidator.validate(result) == true)
    }

    @Test func acceptsTypicalJPYPrice() {
        let result = PriceResult(price: 1980, currency: "JPY", extractMethod: .schemaOrg, confidence: 0.95)
        #expect(PriceValidator.validate(result) == true)
    }

    @Test func rejectsUSDAbove100K() {
        let result = PriceResult(price: 100_001, currency: "USD", extractMethod: .metaTag, confidence: 0.85)
        #expect(PriceValidator.validate(result) == false)
    }

    @Test func acceptsUSDAt100K() {
        let result = PriceResult(price: 100_000, currency: "USD", extractMethod: .metaTag, confidence: 0.85)
        #expect(PriceValidator.validate(result) == true)
    }

    @Test func acceptsTypicalUSDPrice() {
        let result = PriceResult(price: Decimal(string: "19.99")!, currency: "USD", extractMethod: .metaTag, confidence: 0.85)
        #expect(PriceValidator.validate(result) == true)
    }

    @Test func rejectsEURAbove100K() {
        let result = PriceResult(price: 150_000, currency: "EUR", extractMethod: .metaTag, confidence: 0.85)
        #expect(PriceValidator.validate(result) == false)
    }

    @Test func acceptsTypicalEURPrice() {
        let result = PriceResult(price: Decimal(string: "29.99")!, currency: "EUR", extractMethod: .metaTag, confidence: 0.85)
        #expect(PriceValidator.validate(result) == true)
    }

    @Test func rejectsGBPAbove100K() {
        let result = PriceResult(price: 200_000, currency: "GBP", extractMethod: .metaTag, confidence: 0.85)
        #expect(PriceValidator.validate(result) == false)
    }

    @Test func acceptsUnknownCurrencyWithNoUpperLimit() {
        // Other currencies: accept with no upper limit check
        let result = PriceResult(price: 9_999_999, currency: "KRW", extractMethod: .schemaOrg, confidence: 0.95)
        #expect(PriceValidator.validate(result) == true)
    }

    @Test func acceptsUnknownCurrencyLargeAmount() {
        let result = PriceResult(price: 50_000_000, currency: "IDR", extractMethod: .schemaOrg, confidence: 0.95)
        #expect(PriceValidator.validate(result) == true)
    }
}

// MARK: - SchemaOrgExtractor Tests

struct SchemaOrgExtractorTests {

    private func makeDocument(_ html: String) -> Document {
        (try? SwiftSoup.parse(html)) ?? Document("")
    }

    @Test func extractsOfferPriceFromProduct() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Product","name":"Test Item","offers":{"@type":"Offer","price":"1980","priceCurrency":"JPY"}}
        </script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        let first = results.first!
        #expect(first.price == Decimal(1980))
        #expect(first.currency == "JPY")
        #expect(first.extractMethod == .schemaOrg)
        #expect(first.confidence == 0.95)
    }

    @Test func extractsOfferPriceAsNumber() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Product","offers":{"@type":"Offer","price":29.99,"priceCurrency":"USD"}}
        </script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(string: "29.99")!)
        #expect(results.first!.currency == "USD")
    }

    @Test func extractsAggregateOfferLowPrice() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Product","offers":{"@type":"AggregateOffer","lowPrice":1980,"priceCurrency":"JPY"}}
        </script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(1980))
        #expect(results.first!.currency == "JPY")
    }

    @Test func extractsFromGraphArray() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@context":"https://schema.org","@graph":[{"@type":"WebSite","name":"Test"},{"@type":"Product","offers":{"@type":"Offer","price":"3980","priceCurrency":"JPY"}}]}
        </script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(3980))
        #expect(results.first!.currency == "JPY")
    }

    @Test func extractsFromDirectOfferType() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Offer","price":"9.99","priceCurrency":"USD"}
        </script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(string: "9.99")!)
        #expect(results.first!.currency == "USD")
    }

    @Test func extractsFromOffersArray() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Product","offers":[{"@type":"Offer","price":"1500","priceCurrency":"JPY"},{"@type":"Offer","price":"2000","priceCurrency":"JPY"}]}
        </script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        // Should extract at least one result
        #expect(results.first!.currency == "JPY")
    }

    @Test func returnsEmptyForNoScriptTags() throws {
        let html = "<html><body><p>No JSON-LD here</p></body></html>"
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(results.isEmpty)
    }

    @Test func returnsEmptyForNonProductSchema() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Organization","name":"ACME Corp"}
        </script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(results.isEmpty)
    }

    @Test func handlesMultipleScriptBlocks() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">{"@type":"WebSite","name":"Shop"}</script>
        <script type="application/ld+json">{"@type":"Product","offers":{"@type":"Offer","price":"5500","priceCurrency":"JPY"}}</script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(5500))
    }

    @Test func handlesMalformedJSON() throws {
        let html = """
        <html><body>
        <script type="application/ld+json">{ not valid json }</script>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = SchemaOrgExtractor()
        let results = extractor.extract(from: doc)
        #expect(results.isEmpty)
    }
}

// MARK: - MetaTagExtractor Tests

struct MetaTagExtractorTests {

    private func makeDocument(_ html: String) -> Document {
        (try? SwiftSoup.parse(html)) ?? Document("")
    }

    @Test func extractsOGPriceAmount() throws {
        let html = """
        <html><head>
        <meta property="og:price:amount" content="19.99">
        <meta property="og:price:currency" content="USD">
        </head><body></body></html>
        """
        let doc = makeDocument(html)
        let extractor = MetaTagExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(string: "19.99")!)
        #expect(results.first!.currency == "USD")
        #expect(results.first!.extractMethod == .metaTag)
        #expect(results.first!.confidence == 0.85)
    }

    @Test func extractsProductPriceAmount() throws {
        let html = """
        <html><head>
        <meta property="product:price:amount" content="1980">
        <meta property="product:price:currency" content="JPY">
        </head><body></body></html>
        """
        let doc = makeDocument(html)
        let extractor = MetaTagExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(1980))
        #expect(results.first!.currency == "JPY")
    }

    @Test func returnsEmptyWhenNoMetaTags() throws {
        let html = "<html><head><title>Shop</title></head><body></body></html>"
        let doc = makeDocument(html)
        let extractor = MetaTagExtractor()
        let results = extractor.extract(from: doc)
        #expect(results.isEmpty)
    }

    @Test func returnsEmptyWhenAmountPresentButCurrencyMissing() throws {
        let html = """
        <html><head>
        <meta property="og:price:amount" content="19.99">
        </head><body></body></html>
        """
        let doc = makeDocument(html)
        let extractor = MetaTagExtractor()
        let results = extractor.extract(from: doc)
        #expect(results.isEmpty)
    }

    @Test func handlesJPYAmountWithCurrency() throws {
        let html = """
        <html><head>
        <meta property="og:price:amount" content="2980">
        <meta property="og:price:currency" content="JPY">
        </head><body></body></html>
        """
        let doc = makeDocument(html)
        let extractor = MetaTagExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(2980))
        #expect(results.first!.currency == "JPY")
    }
}

// MARK: - DataAttributeExtractor Tests

struct DataAttributeExtractorTests {

    private func makeDocument(_ html: String) -> Document {
        (try? SwiftSoup.parse(html)) ?? Document("")
    }

    @Test func extractsDataPriceAttribute() throws {
        let html = """
        <html><body>
        <span data-price="¥1,980">¥1,980</span>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = DataAttributeExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(1980))
        #expect(results.first!.currency == "JPY")
        #expect(results.first!.extractMethod == .dataAttribute)
        #expect(results.first!.confidence == 0.75)
    }

    @Test func extractsDataProductPriceAttribute() throws {
        let html = """
        <html><body>
        <div data-product-price="$29.99" class="product-card">Item</div>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = DataAttributeExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(string: "29.99")!)
        #expect(results.first!.currency == "USD")
    }

    @Test func extractsDataAmountAttribute() throws {
        let html = """
        <html><body>
        <button data-amount="£19.99">Add to Cart</button>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = DataAttributeExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.currency == "GBP")
    }

    @Test func extractsDataSalePriceAttribute() throws {
        let html = """
        <html><body>
        <span data-sale-price="€14.99">Sale!</span>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = DataAttributeExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.currency == "EUR")
    }

    @Test func returnsEmptyWhenNoDataAttributes() throws {
        let html = "<html><body><span class=\"price\">¥1,980</span></body></html>"
        let doc = makeDocument(html)
        let extractor = DataAttributeExtractor()
        let results = extractor.extract(from: doc)
        #expect(results.isEmpty)
    }

    @Test func returnsEmptyWhenDataAttributeHasNoCurrency() throws {
        let html = """
        <html><body>
        <span data-price="1980">1980</span>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = DataAttributeExtractor()
        let results = extractor.extract(from: doc)
        #expect(results.isEmpty)
    }
}

// MARK: - HTMLPatternExtractor Tests

struct HTMLPatternExtractorTests {

    private func makeDocument(_ html: String) -> Document {
        (try? SwiftSoup.parse(html)) ?? Document("")
    }

    @Test func extractsPriceFromPriceClass() throws {
        let html = """
        <html><body>
        <span class="price">¥1,980</span>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = HTMLPatternExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.price == Decimal(1980))
        #expect(results.first!.currency == "JPY")
        #expect(results.first!.extractMethod == .htmlPattern)
    }

    @Test func extractsPriceFromPriceId() throws {
        let html = """
        <html><body>
        <span id="price">$29.99</span>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = HTMLPatternExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.currency == "USD")
    }

    @Test func extractsPriceFromProductPriceClass() throws {
        let html = """
        <html><body>
        <div class="product-price">€29.99</div>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = HTMLPatternExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.currency == "EUR")
    }

    @Test func extractsPriceFromClassContainingPriceWord() throws {
        let html = """
        <html><body>
        <span class="sale-price-display">$49.99</span>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = HTMLPatternExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        #expect(results.first!.currency == "USD")
    }

    @Test func cssStrategyConfidenceHigherThanRegex() throws {
        let html = """
        <html><body>
        <span class="price">$19.99</span>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = HTMLPatternExtractor()
        let results = extractor.extract(from: doc)
        #expect(!results.isEmpty)
        // CSS selector confidence is 0.60
        #expect(results.first!.confidence == 0.60)
    }

    @Test func returnsAtMostThreeResults() throws {
        let html = """
        <html><body>
        <span class="price">$10.00</span>
        <div class="product-price">$20.00</div>
        <p id="price">$30.00</p>
        <span class="sale-price">$40.00</span>
        <span class="item-price">$50.00</span>
        </body></html>
        """
        let doc = makeDocument(html)
        let extractor = HTMLPatternExtractor()
        let results = extractor.extract(from: doc)
        #expect(results.count <= 3)
    }
}

// MARK: - PriceExtractionPipeline Tests

struct PriceExtractionPipelineTests {

    @Test func pipelineExtractsFromSchemaOrg() {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Product","offers":{"@type":"Offer","price":"1980","priceCurrency":"JPY"}}
        </script>
        </body></html>
        """
        let pipeline = PriceExtractionPipeline()
        let result = pipeline.extract(from: html)
        #expect(result != nil)
        #expect(result!.result.price == Decimal(1980))
        #expect(result!.result.currency == "JPY")
        #expect(result!.method == .schemaOrg)
    }

    @Test func pipelineFailsOverToMetaTags() {
        // No JSON-LD, falls through to meta tags
        let html = """
        <html><head>
        <meta property="og:price:amount" content="19.99">
        <meta property="og:price:currency" content="USD">
        </head><body></body></html>
        """
        let pipeline = PriceExtractionPipeline()
        let result = pipeline.extract(from: html)
        #expect(result != nil)
        #expect(result!.result.currency == "USD")
        #expect(result!.method == .metaTag)
    }

    @Test func pipelineFailsOverToDataAttributes() {
        // No JSON-LD, no meta tags, falls through to data attributes
        let html = """
        <html><body>
        <span data-price="¥2,500">¥2,500</span>
        </body></html>
        """
        let pipeline = PriceExtractionPipeline()
        let result = pipeline.extract(from: html)
        #expect(result != nil)
        #expect(result!.result.currency == "JPY")
        #expect(result!.method == .dataAttribute)
    }

    @Test func pipelineFailsOverToHTMLPattern() {
        // No JSON-LD, no meta tags, no data attributes, falls through to HTML pattern
        let html = """
        <html><body>
        <span class="price">£9.99</span>
        </body></html>
        """
        let pipeline = PriceExtractionPipeline()
        let result = pipeline.extract(from: html)
        #expect(result != nil)
        #expect(result!.result.currency == "GBP")
        #expect(result!.method == .htmlPattern)
    }

    @Test func pipelineReturnsNilWhenNoPriceFound() {
        let html = """
        <html><body>
        <h1>Welcome to our store</h1>
        <p>Check back later for prices.</p>
        </body></html>
        """
        let pipeline = PriceExtractionPipeline()
        let result = pipeline.extract(from: html)
        #expect(result == nil)
    }

    @Test func pipelineReturnsNilForEmptyHTML() {
        let pipeline = PriceExtractionPipeline()
        let result = pipeline.extract(from: "")
        #expect(result == nil)
    }

    @Test func pipelineFiltersInvalidPricesFromExtractors() {
        // Schema.org block with price=0 — should be rejected by validator and pipeline should
        // continue or return nil
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Product","offers":{"@type":"Offer","price":"0","priceCurrency":"JPY"}}
        </script>
        </body></html>
        """
        let pipeline = PriceExtractionPipeline()
        let result = pipeline.extract(from: html)
        // Price 0 is invalid; no other extractor has data, so nil
        #expect(result == nil)
    }

    @Test func pipelinePrefersHigherPriorityExtractor() {
        // Both JSON-LD and meta tags present — should use JSON-LD (higher priority)
        let html = """
        <html><head>
        <meta property="og:price:amount" content="99.99">
        <meta property="og:price:currency" content="USD">
        </head><body>
        <script type="application/ld+json">
        {"@type":"Product","offers":{"@type":"Offer","price":"1980","priceCurrency":"JPY"}}
        </script>
        </body></html>
        """
        let pipeline = PriceExtractionPipeline()
        let result = pipeline.extract(from: html)
        #expect(result != nil)
        #expect(result!.method == .schemaOrg)
        #expect(result!.result.currency == "JPY")
    }
}

// MARK: - MetadataExtractor Tests

struct MetadataExtractorTests {

    @Test func extractsTitleFromOGTag() {
        let html = """
        <html><head>
        <meta property="og:title" content="Amazing Product">
        <title>Shop - Amazing Product</title>
        </head><body></body></html>
        """
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product/123")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.title == "Amazing Product")
    }

    @Test func fallsBackToTitleTagWhenNoOGTitle() {
        let html = """
        <html><head>
        <title>Product Page</title>
        </head><body></body></html>
        """
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.title == "Product Page")
    }

    @Test func extractsCanonicalURL() {
        let html = """
        <html><head>
        <link rel="canonical" href="https://example.com/product/canonical">
        </head><body></body></html>
        """
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product/123?ref=search")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.resolvedUrl == "https://example.com/product/canonical")
    }

    @Test func fallsBackToOGURLWhenNoCanonical() {
        let html = """
        <html><head>
        <meta property="og:url" content="https://example.com/product/og-url">
        </head><body></body></html>
        """
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.resolvedUrl == "https://example.com/product/og-url")
    }

    @Test func resolvedURLIsNilForRelativeCanonical() {
        let html = """
        <html><head>
        <link rel="canonical" href="/product/relative">
        </head><body></body></html>
        """
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        // Relative URL is not absolute, so resolvedUrl should be nil
        #expect(metadata.resolvedUrl == nil)
    }

    @Test func extractsImageFromOGImageTag() {
        let html = """
        <html><head>
        <meta property="og:image" content="https://example.com/images/product.jpg">
        </head><body></body></html>
        """
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.imageUrl == "https://example.com/images/product.jpg")
    }

    @Test func imageURLIsNilWhenNoOGImage() {
        let html = "<html><head><title>Shop</title></head><body></body></html>"
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.imageUrl == nil)
    }

    @Test func extractsProductIDHintsFromJSONLD() {
        let html = """
        <html><body>
        <script type="application/ld+json">
        {"@type":"Product","sku":"ABC-123","gtin":"01234567890128","mpn":"XYZ-456","productID":"PROD-789"}
        </script>
        </body></html>
        """
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.productIdHints.contains("ABC-123"))
        #expect(metadata.productIdHints.contains("01234567890128"))
        #expect(metadata.productIdHints.contains("XYZ-456"))
        #expect(metadata.productIdHints.contains("PROD-789"))
    }

    @Test func productIDHintsEmptyWhenNoJSONLD() {
        let html = "<html><body><p>Product page</p></body></html>"
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.productIdHints.isEmpty)
    }

    @Test func titleIsNilWhenNoTitleTags() {
        let html = "<html><head></head><body></body></html>"
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.title == nil)
    }

    @Test func resolvedURLIsNilWhenNoCanonicalOrOGURL() {
        let html = "<html><head><title>Shop</title></head><body></body></html>"
        let extractor = MetadataExtractor()
        let url = URL(string: "https://example.com/product")!
        let metadata = extractor.extract(from: html, requestUrl: url)
        #expect(metadata.resolvedUrl == nil)
    }
}
