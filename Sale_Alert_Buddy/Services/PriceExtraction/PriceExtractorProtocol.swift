// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import SwiftSoup

protocol PriceExtractor: Sendable {
    func extract(from document: Document) -> [PriceResult]
}
