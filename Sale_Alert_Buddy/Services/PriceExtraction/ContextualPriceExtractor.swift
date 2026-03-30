import Foundation
import SwiftSoup

struct ContextualPriceExtractor: PriceExtractor {

    private static let strongPositiveKeywords = [
        "current", "sale", "selling", "special", "final", "offer",
        "販売価格", "税込", "セール価格", "特価", "現金特価", "タイムセール", "値引き", "割引"
    ]

    private static let genericPriceKeywords = [
        "price", "価格"
    ]

    private static let negativeKeywords = [
        "point", "reward", "list", "original", "usual", "regular", "reference",
        "ポイント", "還元", "希望小売価格", "通常価格", "参考価格", "メーカー希望小売価格",
        "送料", "shipping"
    ]

    private static let sectionNegativeKeywords = [
        "recommend", "recommended", "related", "ranking", "review", "history",
        "recent", "pickup", "banner", "campaign", "coupon", "suggest", "similar",
        "favorite", "おすすめ", "関連", "ランキング", "レビュー", "閲覧履歴",
        "履歴", "特集", "キャンペーン", "クーポン", "お気に入り"
    ]

    private static let likelySelectors = [
        "[data-price]",
        "[data-sale-price]",
        "[data-product-price]",
        "[class*='price']",
        "[class*='Price']",
        "[id*='price']",
        "[class*='sale']",
        "[id*='sale']",
        "[class*='current']",
        "[id*='current']"
    ]

    func extract(from document: Document) -> [PriceResult] {
        var bestByKey: [String: PriceResult] = [:]

        for result in extractLabeledRows(from: document) + extractLikelyContainers(from: document) {
            let key = "\(result.currency)|\(result.price)"
            if let existing = bestByKey[key], existing.confidence >= result.confidence {
                continue
            }
            bestByKey[key] = result
        }

        return bestByKey.values.sorted { $0.confidence > $1.confidence }
    }

    private func extractLabeledRows(from document: Document) -> [PriceResult] {
        var results: [PriceResult] = []

        if let rows = try? document.select("tr") {
            for row in rows.array() {
                let labelText = normalized(try? row.select("th,td").first()?.text())
                guard isPriceRelevant(labelText) else { continue }

                let valueCells = (try? row.select("td"))?.array() ?? []
                for cell in valueCells {
                    guard let text = try? cell.text(),
                          let parsed = PriceCurrencyParser.parse(text) else {
                        continue
                    }

                    let confidence = contextualConfidence(
                        label: labelText,
                        context: normalized(contextText(for: cell)),
                        parsedPrice: parsed.price
                    )
                    if confidence > 0.55 {
                        results.append(PriceResult(
                            price: parsed.price,
                            currency: parsed.currency,
                            extractMethod: .htmlContext,
                            confidence: confidence
                        ))
                    }
                }
            }
        }

        if let rows = try? document.select("dl") {
            for row in rows.array() {
                let labelText = normalized(try? row.select("dt").first()?.text())
                guard isPriceRelevant(labelText),
                      let valueText = try? row.select("dd").text(),
                      let parsed = PriceCurrencyParser.parse(valueText) else {
                    continue
                }

                let confidence = contextualConfidence(
                    label: labelText,
                    context: normalized(contextText(for: row)),
                    parsedPrice: parsed.price
                )
                if confidence > 0.55 {
                    results.append(PriceResult(
                        price: parsed.price,
                        currency: parsed.currency,
                        extractMethod: .htmlContext,
                        confidence: confidence
                    ))
                }
            }
        }

        return results
    }

    private func extractLikelyContainers(from document: Document) -> [PriceResult] {
        guard let elements = try? document.select(Self.likelySelectors.joined(separator: ",")) else {
            return []
        }

        return elements.array().compactMap { element in
            guard let text = try? element.text(),
                  let parsed = PriceCurrencyParser.parse(text) else {
                return nil
            }

            let label = normalized(try? element.parent()?.select("th,dt,.label,[class*='label'],[class*='ttl']").first()?.text())
            let confidence = contextualConfidence(
                label: label,
                context: normalized(contextText(for: element)),
                parsedPrice: parsed.price
            )

            guard confidence > 0.52 else { return nil }

            return PriceResult(
                price: parsed.price,
                currency: parsed.currency,
                extractMethod: .htmlContext,
                confidence: confidence
            )
        }
    }

    private func contextualConfidence(label: String, context: String, parsedPrice: Decimal) -> Double {
        var confidence = 0.64
        let combined = [label, context].joined(separator: " ")
        let negativeCount = keywordCount(in: combined, matching: Self.negativeKeywords)
        let sectionNegativeCount = keywordCount(in: combined, matching: Self.sectionNegativeKeywords)
        let strongPositiveCount = keywordCount(in: combined, matching: Self.strongPositiveKeywords)
        let genericPositiveCount = negativeCount == 0
            ? keywordCount(in: combined, matching: Self.genericPriceKeywords)
            : 0

        confidence += min(Double(strongPositiveCount) * 0.09, 0.27)
        confidence += min(Double(genericPositiveCount) * 0.05, 0.10)
        confidence -= min(Double(negativeCount) * 0.16, 0.48)
        confidence -= min(Double(sectionNegativeCount) * 0.18, 0.54)

        if context.contains("tax") || context.contains("税込") || context.contains("円") || context.contains("¥") || context.contains("￥") {
            confidence += 0.04
        }
        if negativeCount > 0 && strongPositiveCount == 0 {
            confidence -= 0.08
        }
        if sectionNegativeCount > 0 && strongPositiveCount == 0 {
            confidence -= 0.10
        }
        if negativeCount > 0 && parsedPrice <= 999 {
            confidence -= 0.08
        }

        return max(0, min(confidence, 0.93))
    }

    private func isPriceRelevant(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let hasNegative = Self.negativeKeywords.contains { value.contains($0) }
        return Self.strongPositiveKeywords.contains { value.contains($0) } ||
            (!hasNegative && Self.genericPriceKeywords.contains { value.contains($0) })
    }

    private func contextText(for element: Element) -> String {
        var values: [String] = [
            (try? element.text()) ?? "",
            element.id(),
            (try? element.className()) ?? "",
            (try? element.attr("data-price")) ?? "",
            (try? element.attr("data-sale-price")) ?? "",
            (try? element.attr("data-product-price")) ?? "",
            (try? element.attr("aria-label")) ?? ""
        ]

        if let previous = try? element.previousElementSibling() {
            values.append((try? previous.text()) ?? "")
        }
        if let next = try? element.nextElementSibling() {
            values.append((try? next.text()) ?? "")
        }
        if let parent = element.parent() {
            values.append((try? parent.text()) ?? "")
            values.append(parent.id())
            values.append((try? parent.className()) ?? "")
            values.append((try? parent.attr("aria-label")) ?? "")
            values.append((try? parent.select("th,dt,.label,[class*='label'],[class*='ttl']").text()) ?? "")
        }

        return values
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func normalized(_ value: String?) -> String {
        value?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    private func keywordCount(in value: String, matching keywords: [String]) -> Int {
        keywords.reduce(into: 0) { count, keyword in
            if value.contains(keyword) {
                count += 1
            }
        }
    }
}
