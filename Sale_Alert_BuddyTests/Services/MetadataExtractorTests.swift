import Testing
import Foundation
@testable import Sale_Alert_Buddy

@Suite("MetadataExtractor Images")
struct MetadataExtractorImageTests {

    private let extractor = MetadataExtractor()
    private let genericURL = URL(string: "https://example.com/product")!
    private let amazonURL = URL(string: "https://www.amazon.co.jp/dp/B00TEST123")!

    // MARK: - Standard meta tag extraction

    @Test("og:image is returned when present")
    func ogImageExtracted() {
        let html = """
        <html><head>
        <meta property="og:image" content="https://example.com/image.jpg"/>
        </head></html>
        """
        let result = extractor.extract(from: html, requestUrl: genericURL)
        #expect(result.imageUrl == "https://example.com/image.jpg")
    }

    @Test("twitter:image used as fallback when og:image is absent")
    func twitterImageFallback() {
        let html = """
        <html><head>
        <meta name="twitter:image" content="https://example.com/tw.jpg"/>
        </head></html>
        """
        let result = extractor.extract(from: html, requestUrl: genericURL)
        #expect(result.imageUrl == "https://example.com/tw.jpg")
    }

    @Test("relative image URL is rejected")
    func relativeImageRejected() {
        let html = """
        <html><head>
        <meta property="og:image" content="/images/product.jpg"/>
        </head></html>
        """
        let result = extractor.extract(from: html, requestUrl: genericURL)
        #expect(result.imageUrl == nil)
    }

    @Test("nil returned when no image meta tags present")
    func noImageReturnsNil() {
        let html = "<html><head><title>No image here</title></head></html>"
        let result = extractor.extract(from: html, requestUrl: genericURL)
        #expect(result.imageUrl == nil)
    }

    // MARK: - Amazon-specific image extraction

    @Test("Amazon: data-a-dynamic-image largest URL is selected")
    func amazonDynamicImageLargestSelected() {
        let dynamicJson = """
        {"https://small.jpg":[500,500],"https://large.jpg":[1500,1500],"https://medium.jpg":[800,800]}
        """
        let html = """
        <html><body>
        <img id="landingImage" data-a-dynamic-image='\(dynamicJson)' src="https://small.jpg"/>
        </body></html>
        """
        let result = extractor.extract(from: html, requestUrl: amazonURL)
        #expect(result.imageUrl == "https://large.jpg")
    }

    @Test("Amazon: #landingImage src used when no data-a-dynamic-image")
    func amazonLandingImageSrcFallback() {
        let html = """
        <html><body>
        <img id="landingImage" src="https://m.media-amazon.com/images/I/product.jpg"/>
        </body></html>
        """
        let result = extractor.extract(from: html, requestUrl: amazonURL)
        #expect(result.imageUrl == "https://m.media-amazon.com/images/I/product.jpg")
    }

    @Test("Amazon: og:image preferred over DOM selectors")
    func amazonOgImagePreferredOverSelectors() {
        let html = """
        <html><head>
        <meta property="og:image" content="https://og-image.jpg"/>
        </head><body>
        <img id="landingImage" src="https://landing-image.jpg"/>
        </body></html>
        """
        let result = extractor.extract(from: html, requestUrl: amazonURL)
        #expect(result.imageUrl == "https://og-image.jpg")
    }

    @Test("non-Amazon host does not use Amazon DOM selectors")
    func nonAmazonDoesNotUseAmazonSelectors() {
        let html = """
        <html><body>
        <img id="landingImage" src="https://some-store.com/image.jpg"/>
        </body></html>
        """
        let result = extractor.extract(from: html, requestUrl: genericURL)
        #expect(result.imageUrl == nil)
    }

    @Test("Amazon: amzn.asia host triggers Amazon extraction")
    func amznAsiaHostTriggersAmazonExtraction() {
        let amznAsiaURL = URL(string: "https://amzn.asia/d/00kCpMXL")!
        let html = """
        <html><body>
        <img id="landingImage" src="https://m.media-amazon.com/images/I/amzn-product.jpg"/>
        </body></html>
        """
        let result = extractor.extract(from: html, requestUrl: amznAsiaURL)
        #expect(result.imageUrl == "https://m.media-amazon.com/images/I/amzn-product.jpg")
    }

    @Test("Amazon: imgTagWrapperId img used as last resort")
    func amazonImgTagWrapperFallback() {
        let html = """
        <html><body>
        <div id="imgTagWrapperId">
        <img src="https://m.media-amazon.com/images/I/wrapper.jpg"/>
        </div>
        </body></html>
        """
        let result = extractor.extract(from: html, requestUrl: amazonURL)
        #expect(result.imageUrl == "https://m.media-amazon.com/images/I/wrapper.jpg")
    }
}
