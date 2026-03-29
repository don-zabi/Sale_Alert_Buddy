// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct DataAttributeExtractor: PriceExtractor {

    /// Data attributes to scan, in priority order.
    private static let priceAttributes: [(name: String, confidence: Double)] = [
        ("data-shade-tax-price", 0.82),
        ("data-taxed-price", 0.82),
        ("data-tax-price", 0.82),
        ("data-price", 0.75),
        ("data-product-price", 0.75),
        ("data-amount", 0.75),
        ("data-sale-price", 0.75)
    ]

    func extract(from document: Document) -> [PriceResult] {
        var results: [PriceResult] = []

        for attribute in Self.priceAttributes {
            guard let elements = try? document.select("[\(attribute.name)]") else { continue }

            for element in elements {
                guard let value = try? element.attr(attribute.name), !value.isEmpty else { continue }

                guard let parsed = PriceCurrencyParser.parse(value) else { continue }

                results.append(PriceResult(
                    price: parsed.price,
                    currency: parsed.currency,
                    extractMethod: .dataAttribute,
                    confidence: attribute.confidence
                ))
            }
        }

        return results
    }
}
