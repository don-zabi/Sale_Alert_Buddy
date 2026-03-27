// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct DataAttributeExtractor: PriceExtractor {

    /// Data attributes to scan, in priority order.
    private static let priceAttributes = [
        "data-price",
        "data-product-price",
        "data-amount",
        "data-sale-price"
    ]

    func extract(from document: Document) -> [PriceResult] {
        var results: [PriceResult] = []

        for attribute in Self.priceAttributes {
            guard let elements = try? document.select("[\(attribute)]") else { continue }

            for element in elements {
                guard let value = try? element.attr(attribute), !value.isEmpty else { continue }

                guard let parsed = PriceCurrencyParser.parse(value) else { continue }

                results.append(PriceResult(
                    price: parsed.price,
                    currency: parsed.currency,
                    extractMethod: .dataAttribute,
                    confidence: 0.75
                ))
            }
        }

        return results
    }
}
