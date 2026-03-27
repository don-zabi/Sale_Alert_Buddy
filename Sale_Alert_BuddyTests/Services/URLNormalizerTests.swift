import Testing
import Foundation
@testable import Sale_Alert_Buddy

struct URLNormalizerTests {

    // MARK: - Tracking Parameter Removal

    @Test func amazonURLRemovesRefAndDibParams() {
        let input = "https://www.amazon.co.jp/dp/B001ABCDEF?ref=sr_1_1&dib=abc123&dib_tag=se&keywords=test"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        let url = result!
        #expect(!url.contains("ref="))
        #expect(!url.contains("dib="))
        #expect(!url.contains("dib_tag="))
        #expect(url.contains("keywords=test"))
    }

    @Test func rakutenURLRemovesScid() {
        let input = "https://item.rakuten.co.jp/shop/item123/?scid=af_pc_etc&sc_i=rk_pc_srp_lp_01"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        let url = result!
        #expect(!url.contains("scid="))
        #expect(!url.contains("sc_i="))
    }

    @Test func yahooURLRemovesScI() {
        let input = "https://shopping.yahoo.co.jp/product/abc?sc_i=shp_pc_search_result_1_title"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(!result!.contains("sc_i="))
    }

    @Test func utmParamsAllRemoved() {
        let input = "https://example.com/product?utm_source=google&utm_medium=cpc&utm_campaign=summer&utm_content=banner&utm_term=sale"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        let url = result!
        #expect(!url.contains("utm_source"))
        #expect(!url.contains("utm_medium"))
        #expect(!url.contains("utm_campaign"))
        #expect(!url.contains("utm_content"))
        #expect(!url.contains("utm_term"))
    }

    @Test func fbclidRemoved() {
        let input = "https://example.com/product?fbclid=IwAR12345abcdef"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(!result!.contains("fbclid"))
    }

    @Test func gclidRemoved() {
        let input = "https://example.com/product?gclid=Cj0KCQ123"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(!result!.contains("gclid"))
    }

    @Test func msclkidRemoved() {
        let input = "https://example.com/product?msclkid=abc123def"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(!result!.contains("msclkid"))
    }

    @Test func sourceLocationRemoved() {
        let input = "https://example.com/product?source_location=header_nav"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(!result!.contains("source_location"))
    }

    @Test func refUnderscoreRemoved() {
        let input = "https://example.com/product?ref_=nav_cs_gb"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(!result!.contains("ref_="))
    }

    // MARK: - URL Normalization

    @Test func trailingSlashRemovedFromPath() {
        let input = "https://example.com/"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(result! == "https://example.com")
    }

    @Test func trailingSlashRemovedFromDeepPath() {
        let input = "https://example.com/products/shoes/"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(result! == "https://example.com/products/shoes")
    }

    @Test func schemeAndHostLowercased() {
        let input = "HTTPS://Amazon.CO.JP/dp/B001ABCDEF"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(result!.hasPrefix("https://amazon.co.jp/"))
    }

    @Test func schemeAndHostLowercasedPreservesPath() {
        let input = "HTTPS://Amazon.CO.JP/dp/B001ABCDEF"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(result!.contains("/dp/B001ABCDEF"))
    }

    @Test func queryParamsSortedAlphabetically() {
        let input = "https://example.com/product?zzz=last&aaa=first&mmm=middle"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        let url = result!
        let aaaIdx = url.range(of: "aaa=first")?.lowerBound
        let mmmIdx = url.range(of: "mmm=middle")?.lowerBound
        let zzzIdx = url.range(of: "zzz=last")?.lowerBound
        #expect(aaaIdx != nil && mmmIdx != nil && zzzIdx != nil)
        #expect(aaaIdx! < mmmIdx!)
        #expect(mmmIdx! < zzzIdx!)
    }

    @Test func queryParamsSortedProducesSameResultRegardlessOfOrder() {
        let input1 = "https://example.com/product?b=2&a=1"
        let input2 = "https://example.com/product?a=1&b=2"
        let result1 = URLNormalizer.normalize(input1)
        let result2 = URLNormalizer.normalize(input2)
        #expect(result1 != nil)
        #expect(result2 != nil)
        #expect(result1! == result2!)
    }

    // MARK: - Invalid / Non-HTTP URLs

    @Test func nonHTTPSchemeReturnsNil() {
        let input = "ftp://example.com/file.txt"
        let result = URLNormalizer.normalize(input)
        #expect(result == nil)
    }

    @Test func httpSchemeIsAccepted() {
        let input = "http://example.com/product"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
    }

    @Test func invalidURLReturnsNil() {
        let input = "not a url at all %%invalid"
        let result = URLNormalizer.normalize(input)
        #expect(result == nil)
    }

    @Test func emptyStringReturnsNil() {
        let result = URLNormalizer.normalize("")
        #expect(result == nil)
    }

    @Test func missingHostReturnsNil() {
        let input = "https:///path/only"
        let result = URLNormalizer.normalize(input)
        #expect(result == nil)
    }

    // MARK: - Clean URLs Unchanged (except normalization)

    @Test func urlWithNoTrackingParamsRoundtrips() {
        let input = "https://example.com/product?color=red&size=large"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(result!.contains("color=red"))
        #expect(result!.contains("size=large"))
    }

    @Test func urlWithNoQueryStringRoundtrips() {
        let input = "https://example.com/dp/B001ABCDEF"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        #expect(result! == "https://example.com/dp/B001ABCDEF")
    }

    @Test func mixedTrackingAndEssentialParams() {
        let input = "https://shop.example.com/item?id=12345&ref=homepage&color=blue&utm_source=email"
        let result = URLNormalizer.normalize(input)
        #expect(result != nil)
        let url = result!
        #expect(url.contains("id=12345"))
        #expect(url.contains("color=blue"))
        #expect(!url.contains("ref="))
        #expect(!url.contains("utm_source"))
    }
}
