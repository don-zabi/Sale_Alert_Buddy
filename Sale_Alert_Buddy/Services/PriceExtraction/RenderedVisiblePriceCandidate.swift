import Foundation

struct RenderedVisiblePriceCandidate {
    let text: String
    let digits: String
    let score: Double
    let contextBefore: String
    let contextAfter: String
    let domPath: String
    let tagName: String
    let elementId: String
    let classNames: [String]
    let ancestorTokens: [String]
    let top: Double
    let left: Double
    let width: Double
    let height: Double
    let fontSize: Double?
    let fontWeight: Double?
    let displayStyle: String?
    let visibilityStyle: String?
    let opacity: Double?
    let distanceToTitle: Double?
    let distanceToBuyButton: Double?
    let distanceToCartArea: Double?
    let isVisible: Bool
    let isAboveTheFold: Bool
    let sameAmountNodeCount: Int
}

enum RenderedVisiblePriceCandidateParser {
    static func parseCandidates(from payload: String?) -> [PriceCandidate] {
        guard let payload,
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let rows: [[String: Any]]
        if let array = json as? [[String: Any]] {
            rows = array
        } else if let dict = json as? [String: Any] {
            rows = [dict]
        } else {
            rows = []
        }

        return rows.compactMap { row in
            guard let text = row["text"] as? String,
                  let parsed = PriceCurrencyParser.parse(text) else {
                return nil
            }

            let score = row["score"] as? Double ?? 0
            let ancestorTokens = (row["ancestorTokens"] as? [String] ?? [])
                .map { normalized($0) }
                .filter { !$0.isEmpty }
            let classNames = (row["classNames"] as? [String] ?? [])
                .map { normalized($0) }
                .filter { !$0.isEmpty }
            let contextBefore = normalized(row["contextBefore"] as? String ?? "")
            let contextAfter = normalized(row["contextAfter"] as? String ?? "")
            let combinedContext = normalized([
                text,
                contextBefore,
                contextAfter,
                ancestorTokens.joined(separator: " ")
            ].joined(separator: " "))
            let positiveFlags = matchedFlags(in: combinedContext, tokens: PriceHeuristics.positiveContextTokens + PriceHeuristics.positiveAncestorTokens)
            let negativeFlags = matchedFlags(in: combinedContext, tokens: PriceHeuristics.negativeContextTokens + PriceHeuristics.sectionNegativeTokens)
            let sectionType = inferSectionType(from: ancestorTokens)
            let top = row["top"] as? Double ?? 0
            let left = row["left"] as? Double ?? 0
            let width = row["width"] as? Double ?? 0
            let height = row["height"] as? Double ?? 0
            let fontSize = row["fontSize"] as? Double
            let fontWeight = row["fontWeight"] as? Double
            let sameAmountNodeCount = row["sameAmountNodeCount"] as? Int ?? 1
            let distanceToTitle = row["distanceToTitle"] as? Double
            let distanceToBuyButton = row["distanceToBuyButton"] as? Double
            let distanceToCartArea = row["distanceToCartArea"] as? Double
            let isVisible = row["isVisible"] as? Bool ?? true
            let isAboveTheFold = row["isAboveTheFold"] as? Bool ?? (top >= 0 && top <= 844 * 0.8)
            let anchorQualityScore = anchorQuality(
                sectionType: sectionType,
                positiveFlags: positiveFlags,
                negativeFlags: negativeFlags,
                distanceToTitle: distanceToTitle,
                distanceToBuyButton: distanceToBuyButton,
                isVisible: isVisible,
                isAboveTheFold: isAboveTheFold,
                sameAmountNodeCount: sameAmountNodeCount,
                fontSize: fontSize
            )

            let clampedScore = min(max(score, 0), 5000)
            let confidence = min(0.96, max(0.68, 0.68 + (clampedScore / 10000)))

            return PriceCandidate(
                amount: parsed.price,
                currency: parsed.currency,
                sourceType: .renderedVisible,
                origin: .renderedDOM,
                rawText: text,
                normalizedText: normalized(text),
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                domPath: row["domPath"] as? String ?? "",
                tagName: normalized(row["tagName"] as? String ?? ""),
                elementId: normalized(row["id"] as? String ?? ""),
                classNames: classNames,
                ancestorTokens: ancestorTokens,
                isVisible: isVisible,
                boundingRect: PriceBoundingRect(top: top, left: left, width: width, height: height),
                top: top,
                left: left,
                width: width,
                height: height,
                distanceToTitle: distanceToTitle,
                distanceToBuyButton: distanceToBuyButton,
                distanceToCartArea: distanceToCartArea,
                isAboveTheFold: isAboveTheFold,
                negativeContextFlags: negativeFlags,
                positiveContextFlags: positiveFlags,
                sectionType: sectionType,
                confidence: confidence,
                debugReasons: ["origin:renderedDOM", "source:renderedVisible"],
                fontSize: fontSize,
                fontWeight: fontWeight,
                displayStyle: row["display"] as? String,
                visibilityStyle: row["visibility"] as? String,
                opacity: row["opacity"] as? Double,
                sameAmountNodeCount: sameAmountNodeCount,
                anchorQualityScore: anchorQualityScore
            )
        }
    }

    static func parseBestResult(from payload: String?) -> PriceResult? {
        guard let best = parseCandidates(from: payload).first else {
            return nil
        }

        return PriceResult(
            price: best.amount,
            currency: best.currency,
            extractMethod: best.extractMethod,
            confidence: best.confidence,
            confidenceLevel: .medium,
            sourceType: best.sourceType,
            anchor: best.anchor
        )
    }

    private static func normalized(_ value: String) -> String {
        PriceDocumentSignals.normalized(value)
    }

    private static func matchedFlags(in value: String, tokens: [String]) -> [String] {
        var matched: [String] = []
        for token in tokens where value.contains(token) && !matched.contains(token) {
            matched.append(token)
        }
        return matched
    }

    private static func inferSectionType(from ancestorTokens: [String]) -> PriceSectionType {
        let combined = ancestorTokens.joined(separator: " ")
        for (sectionType, tokens) in PriceHeuristics.sectionMapping {
            if tokens.contains(where: combined.contains) {
                return sectionType
            }
        }
        return .unknown
    }

    private static func anchorQuality(
        sectionType: PriceSectionType,
        positiveFlags: [String],
        negativeFlags: [String],
        distanceToTitle: Double?,
        distanceToBuyButton: Double?,
        isVisible: Bool,
        isAboveTheFold: Bool,
        sameAmountNodeCount: Int,
        fontSize: Double?
    ) -> Double {
        var score = 0.24
        if isVisible {
            score += 0.08
        }
        if isAboveTheFold {
            score += 0.12
        }
        if let distanceToTitle, distanceToTitle <= 240 {
            score += 0.20
        } else if let distanceToTitle, distanceToTitle <= 420 {
            score += 0.10
        }
        if let distanceToBuyButton, distanceToBuyButton <= 240 {
            score += 0.20
        } else if let distanceToBuyButton, distanceToBuyButton <= 420 {
            score += 0.10
        }
        if let fontSize, fontSize >= 24 {
            score += 0.12
        } else if let fontSize, fontSize >= 18 {
            score += 0.06
        }
        score += min(Double(positiveFlags.count) * 0.03, 0.12)
        score -= min(Double(negativeFlags.count) * 0.06, 0.28)
        if sameAmountNodeCount > 4 {
            score -= min(Double(sameAmountNodeCount - 4) * 0.03, 0.18)
        }
        switch sectionType {
        case .mainProduct:
            score += 0.18
        case .buybox:
            score += 0.22
        case .campaign, .shipping, .review, .recommendation, .related, .ranking, .breadcrumb, .gallery:
            score -= 0.24
        case .unknown:
            break
        }
        return min(1, max(0, score))
    }
}

