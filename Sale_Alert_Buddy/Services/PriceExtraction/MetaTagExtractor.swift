// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct MetaTagExtractor: PriceExtractor {

    /// Meta tag property pairs to check, in priority order.
    private static let tagPairs: [(amount: String, currency: String)] = [
        ("og:price:amount", "og:price:currency"),
        ("product:price:amount", "product:price:currency")
    ]

    func extract(from document: Document) -> [PriceResult] {
        var results: [PriceResult] = []

        for pair in Self.tagPairs {
            guard
                let amountContent = metaContent(in: document, property: pair.amount),
                let currencyContent = metaContent(in: document, property: pair.currency),
                !amountContent.isEmpty,
                !currencyContent.isEmpty
            else {
                continue
            }

            guard let price = Decimal(string: amountContent) else { continue }

            results.append(PriceResult(
                price: price,
                currency: currencyContent.uppercased(),
                extractMethod: .metaTag,
                confidence: 0.85
            ))
        }

        return results
    }

    // MARK: - Private Helpers

    private func metaContent(in document: Document, property: String) -> String? {
        guard let element = try? document.select("meta[property='\(property)']").first() else {
            return nil
        }
        return try? element.attr("content")
    }
}
