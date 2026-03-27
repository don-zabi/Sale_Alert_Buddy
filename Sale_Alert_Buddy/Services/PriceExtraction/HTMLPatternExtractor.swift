// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct HTMLPatternExtractor: PriceExtractor {

    /// CSS selectors targeting likely price containers, in priority order.
    private static let cssSelectors = [
        ".price",
        "#price",
        ".product-price",
        "[class*='price']",
        "[class*='Price']",
        "[id*='price']"
    ]

    /// Text-level regex patterns for each currency.
    private static let textPatterns: [(pattern: String, currency: String)] = [
        (#"[¥￥]([\d,]+)"#,         "JPY"),
        (#"([\d,]+)円"#,            "JPY"),
        (#"\$([\d,]+(?:\.\d+)?)"#,  "USD"),
        (#"€([\d,]+(?:[.,]\d+)?)"#, "EUR"),
        (#"£([\d,]+(?:\.\d+)?)"#,   "GBP")
    ]

    func extract(from document: Document) -> [PriceResult] {
        var candidates: [PriceResult] = []

        // Strategy 1: CSS selectors (confidence 0.60)
        candidates.append(contentsOf: extractViaCSSSelectors(document))

        // Strategy 2: Text regex scan (confidence 0.50)
        candidates.append(contentsOf: extractViaTextRegex(document))

        // Sort by confidence descending and return at most 3
        let sorted = candidates.sorted { $0.confidence > $1.confidence }
        return Array(sorted.prefix(3))
    }

    // MARK: - CSS Selector Strategy

    private func extractViaCSSSelectors(_ document: Document) -> [PriceResult] {
        var results: [PriceResult] = []

        for selector in Self.cssSelectors {
            guard let elements = try? document.select(selector) else { continue }

            for element in elements {
                guard let text = try? element.text(), !text.isEmpty else { continue }
                guard let parsed = PriceCurrencyParser.parse(text) else { continue }

                let result = PriceResult(
                    price: parsed.price,
                    currency: parsed.currency,
                    extractMethod: .htmlPattern,
                    confidence: 0.60
                )
                results.append(result)
            }
        }

        return results
    }

    // MARK: - Text Regex Strategy

    private func extractViaTextRegex(_ document: Document) -> [PriceResult] {
        guard let bodyText = try? document.body()?.text() ?? "" else { return [] }
        var results: [PriceResult] = []

        for (pattern, currency) in Self.textPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(bodyText.startIndex..., in: bodyText)
            let matches = regex.matches(in: bodyText, range: range)

            for match in matches {
                // Group 1 contains the numeric portion
                guard let numRange = Range(match.range(at: 1), in: bodyText) else { continue }
                let numStr = String(bodyText[numRange])

                // Clean up: remove commas for thousands separator
                var cleaned = numStr.replacingOccurrences(of: ",", with: "")
                // EUR European decimal: if currency is EUR and the string had comma as decimal
                if currency == "EUR" {
                    let parts = numStr.components(separatedBy: ",")
                    if parts.count == 2 && parts[1].count == 2 {
                        cleaned = parts[0] + "." + parts[1]
                    }
                }

                guard let price = Decimal(string: cleaned) else { continue }

                results.append(PriceResult(
                    price: price,
                    currency: currency,
                    extractMethod: .htmlPattern,
                    confidence: 0.50
                ))
            }
        }

        return results
    }
}
