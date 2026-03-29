// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct PriceExtractionPipeline: Sendable {

    private let extractors: [any PriceExtractor]

    init() {
        extractors = [
            SchemaOrgExtractor(),
            MetaTagExtractor(),
            DataAttributeExtractor(),
            EmbeddedJSONExtractor(),
            HTMLPatternExtractor()
        ]
    }

    /// Parses the HTML string and runs each extractor in priority order.
    /// Returns the first valid (passing PriceValidator) result found, or nil if all fail.
    func extract(from html: String) -> (result: PriceResult, method: ExtractMethod)? {
        guard !html.isEmpty,
              let document = try? SwiftSoup.parse(html) else {
            return nil
        }

        for extractor in extractors {
            let candidates = extractor.extract(from: document)

            // Find the highest-confidence valid result from this extractor
            let valid = candidates
                .filter { PriceValidator.validate($0) }
                .sorted { $0.confidence > $1.confidence }

            if let best = valid.first {
                return (result: best, method: best.extractMethod)
            }
        }

        return nil
    }
}
