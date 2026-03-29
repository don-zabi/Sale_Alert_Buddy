// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct EmbeddedJSONExtractor: PriceExtractor {

    private static let directPriceKeys: Set<String> = [
        "price",
        "currentprice",
        "saleprice",
        "sellingprice",
        "discountprice",
        "lowprice",
        "minprice"
    ]

    private static let ignoredPriceKeys: Set<String> = [
        "listprice",
        "originalprice",
        "retailprice",
        "usualprice",
        "regularprice",
        "referenceprice",
        "compareatprice"
    ]

    func extract(from document: Document) -> [PriceResult] {
        let pageLikelyJPY = isLikelyJPYPage(document)
        let blobs = candidateBlobs(from: document)

        var bestByKey: [String: PriceResult] = [:]

        for blob in blobs {
            for root in jsonRoots(from: blob) {
                let candidates = extractCandidates(
                    from: root,
                    inheritedCurrency: nil,
                    inPriceContext: false,
                    pageLikelyJPY: pageLikelyJPY
                )

                for candidate in candidates {
                    let key = "\(candidate.currency)|\(candidate.price)"
                    if let existing = bestByKey[key], existing.confidence >= candidate.confidence {
                        continue
                    }
                    bestByKey[key] = candidate
                }
            }
        }

        return bestByKey.values
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Blob Collection

    private func candidateBlobs(from document: Document) -> [String] {
        guard let scripts = try? document.select("script:not([src])") else { return [] }

        return scripts.compactMap { script in
            guard let content = try? script.html() else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let lowercased = trimmed.lowercased()
            guard lowercased.contains("price") ||
                  lowercased.contains("currency") ||
                  lowercased.contains("currentprice") ||
                  lowercased.contains("saleprice") else {
                return nil
            }

            return trimmed
        }
    }

    // MARK: - JSON Parsing

    private func jsonRoots(from blob: String) -> [Any] {
        var roots: [Any] = []

        if let root = parseJSON(blob) {
            roots.append(root)
        }

        for startIndex in assignmentJSONStarts(in: blob) {
            guard let substring = balancedJSONSubstring(in: blob, startingAt: startIndex),
                  let root = parseJSON(substring) else {
                continue
            }
            roots.append(root)
        }

        return roots
    }

    private func parseJSON(_ string: String) -> Any? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func assignmentJSONStarts(in blob: String) -> [String.Index] {
        guard let regex = try? NSRegularExpression(pattern: #"=\s*[\{\[]"#) else { return [] }
        let nsRange = NSRange(blob.startIndex..., in: blob)

        return regex.matches(in: blob, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: blob) else { return nil }
            return blob[range].firstIndex(where: { $0 == "{" || $0 == "[" })
        }
    }

    private func balancedJSONSubstring(in text: String, startingAt start: String.Index) -> String? {
        let opening = text[start]
        guard opening == "{" || opening == "[" else { return nil }
        let closing: Character = opening == "{" ? "}" : "]"

        var depth = 0
        var index = start
        var inString = false
        var isEscaping = false

        while index < text.endIndex {
            let character = text[index]

            if inString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    // MARK: - Candidate Extraction

    private func extractCandidates(
        from node: Any,
        inheritedCurrency: String?,
        inPriceContext: Bool,
        pageLikelyJPY: Bool
    ) -> [PriceResult] {
        if let dict = node as? [String: Any] {
            return extractCandidates(
                from: dict,
                inheritedCurrency: inheritedCurrency,
                inPriceContext: inPriceContext,
                pageLikelyJPY: pageLikelyJPY
            )
        }

        if let array = node as? [Any] {
            return array.flatMap {
                extractCandidates(
                    from: $0,
                    inheritedCurrency: inheritedCurrency,
                    inPriceContext: inPriceContext,
                    pageLikelyJPY: pageLikelyJPY
                )
            }
        }

        return []
    }

    private func extractCandidates(
        from dict: [String: Any],
        inheritedCurrency: String?,
        inPriceContext: Bool,
        pageLikelyJPY: Bool
    ) -> [PriceResult] {
        let resolvedCurrency = currency(from: dict) ?? inheritedCurrency
        let hasPriceContextKey = dict.keys.contains { normalizedKey($0).contains("price") }
        let currentPriceContext = inPriceContext || hasPriceContextKey

        var results: [PriceResult] = []

        for (key, value) in dict {
            let normalized = normalizedKey(key)

            if let candidate = priceResult(
                forKey: normalized,
                value: value,
                currency: resolvedCurrency,
                inPriceContext: currentPriceContext,
                pageLikelyJPY: pageLikelyJPY
            ) {
                results.append(candidate)
            }

            let childPriceContext = currentPriceContext ||
                normalized.contains("price") ||
                normalized == "base" ||
                normalized == "promo"

            results.append(contentsOf: extractCandidates(
                from: value,
                inheritedCurrency: resolvedCurrency,
                inPriceContext: childPriceContext,
                pageLikelyJPY: pageLikelyJPY
            ))
        }

        return results
    }

    private func priceResult(
        forKey key: String,
        value: Any,
        currency: String?,
        inPriceContext: Bool,
        pageLikelyJPY: Bool
    ) -> PriceResult? {
        if Self.ignoredPriceKeys.contains(key) {
            return nil
        }

        let isValueInPriceContext = key == "value" && inPriceContext
        let isDirectPriceKey = Self.directPriceKeys.contains(key)
        guard isDirectPriceKey || isValueInPriceContext else { return nil }

        guard let price = decimal(from: value) else { return nil }

        let resolvedCurrency: String?
        let confidence: Double

        if let explicitCurrency = currency?.uppercased(), !explicitCurrency.isEmpty {
            resolvedCurrency = explicitCurrency
            confidence = isValueInPriceContext ? 0.80 : 0.78
        } else if pageLikelyJPY {
            resolvedCurrency = "JPY"
            confidence = 0.70
        } else {
            resolvedCurrency = nil
            confidence = 0
        }

        guard let resolvedCurrency else { return nil }

        return PriceResult(
            price: price,
            currency: resolvedCurrency,
            extractMethod: .embeddedJSON,
            confidence: confidence
        )
    }

    // MARK: - Helpers

    private func currency(from dict: [String: Any]) -> String? {
        if let priceCurrency = dict["priceCurrency"] as? String, !priceCurrency.isEmpty {
            return priceCurrency
        }

        if let currencyCode = dict["currencyCode"] as? String, !currencyCode.isEmpty {
            return currencyCode
        }

        if let currency = dict["currency"] as? String, !currency.isEmpty {
            return currency
        }

        if let currency = dict["currency"] as? [String: Any],
           let code = currency["code"] as? String,
           !code.isEmpty {
            return code
        }

        return nil
    }

    private func decimal(from value: Any) -> Decimal? {
        if let string = value as? String {
            if let parsed = PriceCurrencyParser.parse(string) {
                return parsed.price
            }

            let cleaned = string.replacingOccurrences(of: ",", with: "")
            return Decimal(string: cleaned)
        }

        if let number = value as? NSNumber {
            return Decimal(string: number.stringValue)
        }

        if let doubleValue = value as? Double {
            return Decimal(string: String(doubleValue))
        }

        if let intValue = value as? Int {
            return Decimal(intValue)
        }

        return nil
    }

    private func normalizedKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isLikelyJPYPage(_ document: Document) -> Bool {
        let html = (try? document.html()) ?? ""
        return html.contains("¥") ||
               html.contains("￥") ||
               html.contains("円") ||
               html.contains("税込") ||
               html.contains("税抜") ||
               html.contains("\"JPY\"") ||
               html.contains("'JPY'")
    }
}
