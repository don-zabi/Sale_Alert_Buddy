import Foundation
import SwiftSoup

struct VisiblePriceSignalScorer {

    private static let candidateSelector = [
        "span", "div", "p", "strong", "b", "em", "label", "td", "li", "dd", "dt",
        "[class*='price']", "[id*='price']", "[data-price]",
        "[class*='sale']", "[id*='sale']",
        "[class*='amount']", "[id*='amount']"
    ].joined(separator: ",")

    private static let strongPositiveKeywords = [
        "current", "sale", "selling", "special", "final", "offer", "discount",
        "販売価格", "税込", "セール価格", "特価", "現金特価", "タイムセール", "割引", "値引き"
    ]

    private static let genericPriceKeywords = [
        "price", "価格"
    ]

    private static let negativeKeywords = [
        "point", "reward", "list", "original", "usual", "regular", "reference",
        "compare", "save", "shipping",
        "ポイント", "還元", "希望小売価格", "通常価格", "参考価格", "メーカー希望小売価格", "送料"
    ]

    private static let sectionNegativeKeywords = [
        "recommend", "recommended", "related", "ranking", "review", "history",
        "recent", "pickup", "banner", "campaign", "coupon", "suggest", "similar",
        "favorite", "おすすめ", "関連", "ランキング", "レビュー", "閲覧履歴",
        "履歴", "特集", "キャンペーン", "クーポン", "お気に入り"
    ]

    private static let overlayKeywords = [
        "floating", "sticky", "header", "footer", "toolbar", "drawer", "sheet",
        "dock", "summary", "quick", "cart", "checkout"
    ]

    private let document: Document

    init(document: Document) {
        self.document = document
    }

    func score(for candidate: PriceResult) -> Double {
        let targetDigits = digitsOnly((candidate.price as NSDecimalNumber).stringValue)
        guard !targetDigits.isEmpty,
              let elements = try? document.select(Self.candidateSelector) else {
            return 0
        }

        var bestScore = -0.12
        var hitCount = 0

        for element in elements.array() {
            guard let text = try? element.text(),
                  !text.isEmpty else {
                continue
            }

            let elementDigits = digitsOnly(text)
            guard elementDigits.contains(targetDigits),
                  text.count <= 160 else {
                continue
            }

            hitCount += 1

            let normalizedText = normalized(text)
            let context = normalized(contextText(for: element))

            let combined = "\(normalizedText) \(context)"
            let negativeCount = keywordCount(in: combined, matching: Self.negativeKeywords)
            let sectionNegativeCount = keywordCount(in: combined, matching: Self.sectionNegativeKeywords)
            let strongPositiveCount = keywordCount(in: combined, matching: Self.strongPositiveKeywords)
            let genericPositiveCount = negativeCount == 0
                ? keywordCount(in: combined, matching: Self.genericPriceKeywords)
                : 0

            var score = 0.10
            score += elementDigits == targetDigits ? 0.18 : 0.05
            if text.contains("¥") || text.contains("￥") || text.contains("円") {
                score += 0.08
            }
            if text.count <= 48 {
                score += 0.04
            }

            score += min(Double(strongPositiveCount) * 0.10, 0.30)
            score += min(Double(genericPositiveCount) * 0.05, 0.10)
            score -= min(Double(negativeCount) * 0.22, 0.66)
            score -= min(Double(sectionNegativeCount) * 0.24, 0.72)
            if negativeCount > 0 && strongPositiveCount == 0 {
                score -= 0.14
            }
            if sectionNegativeCount > 0 && strongPositiveCount == 0 {
                score -= 0.16
            }

            if Self.overlayKeywords.contains(where: context.contains) {
                score -= 0.20
            }

            let tagName = element.tagName().lowercased()
            if ["header", "footer", "nav", "aside"].contains(tagName) {
                score -= 0.18
            }

            bestScore = max(bestScore, score)
        }

        guard hitCount > 0 else { return 0 }

        let repetitionBonus = min(Double(max(hitCount - 1, 0)) * 0.02, 0.08)
        return max(-0.20, min(bestScore + repetitionBonus, 0.45))
    }

    private func contextText(for element: Element) -> String {
        var node: Element? = element
        var values: [String] = []

        if let previous = try? element.previousElementSibling() {
            values.append(truncated((try? previous.text()) ?? ""))
        }
        if let next = try? element.nextElementSibling() {
            values.append(truncated((try? next.text()) ?? ""))
        }
        if let parent = element.parent() {
            values.append(truncated((try? parent.text()) ?? ""))
            values.append(truncated((try? parent.select("th,dt,.label,[class*='label'],[class*='ttl']").text()) ?? ""))
        }

        for _ in 0..<4 {
            guard let current = node else { break }
            values.append(current.tagName())
            values.append(current.id())
            values.append((try? current.className()) ?? "")
            values.append((try? current.attr("aria-label")) ?? "")
            values.append((try? current.attr("data-testid")) ?? "")
            node = current.parent()
        }

        return values.joined(separator: " ")
    }

    private func normalized(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func digitsOnly(_ value: String) -> String {
        value.filter(\.isNumber)
    }

    private func truncated(_ value: String, limit: Int = 120) -> String {
        String(value.prefix(limit))
    }

    private func keywordCount(in value: String, matching keywords: [String]) -> Int {
        keywords.reduce(into: 0) { count, keyword in
            if value.contains(keyword) {
                count += 1
            }
        }
    }
}
