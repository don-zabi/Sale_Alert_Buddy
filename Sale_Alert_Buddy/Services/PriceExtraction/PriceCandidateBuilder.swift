import Foundation
import SwiftSoup

struct PriceCandidateBuilder {

    private let document: Document
    private let origin: PriceCandidateOrigin
    private let referenceSignals: PriceDocumentReferenceSignals

    init(document: Document, origin: PriceCandidateOrigin) {
        self.document = document
        self.origin = origin
        self.referenceSignals = PriceDocumentSignals.extract(from: document)
    }

    func expand(result: PriceResult) -> [PriceCandidate] {
        let sourceType = PriceCandidateFactory.sourceType(for: result.extractMethod)
        let matchingElements = elements(matching: result, sourceType: sourceType)
        let sameAmountNodeCount = max(matchingElements.count, 1)

        let candidates = matchingElements.compactMap { element in
            makeCandidate(
                amount: result.price,
                currency: result.currency,
                sourceType: sourceType,
                baseConfidence: result.confidence,
                element: element,
                sameAmountNodeCount: sameAmountNodeCount
            )
        }

        if !candidates.isEmpty {
            return deduplicated(candidates)
        }

        return [
            PriceCandidate(
                amount: result.price,
                currency: result.currency,
                sourceType: sourceType,
                origin: origin,
                rawText: NSDecimalNumber(decimal: result.price).stringValue,
                normalizedText: NSDecimalNumber(decimal: result.price).stringValue,
                sectionType: .unknown,
                confidence: result.confidence,
                debugReasons: ["fallback-no-dom", "origin:\(origin.debugName)"]
            )
        ]
    }

    func makeCandidate(
        amount: Decimal,
        currency: String,
        sourceType: PriceCandidateSourceType,
        baseConfidence: Double,
        element: Element,
        sameAmountNodeCount: Int
    ) -> PriceCandidate? {
        let rawText = truncated((try? element.text()) ?? "", limit: 220)
        guard !rawText.isEmpty else { return nil }

        let normalizedText = normalized(rawText)
        let contextBefore = truncated(siblingText(of: element, previous: true), limit: 120)
        let contextAfter = truncated(siblingText(of: element, previous: false), limit: 120)
        let classNames = normalizedClassNames(from: (try? element.className()) ?? "")
        let ancestorTokens = collectAncestorTokens(startingAt: element)
        let sectionType = inferSectionType(from: ancestorTokens)
        let combinedContext = normalized([
            rawText,
            contextBefore,
            contextAfter,
            (try? element.attr("aria-label")) ?? "",
            (try? element.attr("title")) ?? "",
            ancestorTokens.joined(separator: " ")
        ].joined(separator: " "))
        let positiveFlags = matchedFlags(in: combinedContext, tokens: PriceHeuristics.positiveContextTokens + PriceHeuristics.positiveAncestorTokens)
        let negativeFlags = matchedFlags(in: combinedContext, tokens: PriceHeuristics.negativeContextTokens + PriceHeuristics.sectionNegativeTokens)
        let distanceToTitle = nearestDOMDistance(from: element, toAny: referenceSignals.titleElements)
        let distanceToBuyButton = nearestDOMDistance(from: element, toAny: referenceSignals.buyButtonElements)
        let isVisible = isLikelyVisible(element: element, ancestorTokens: ancestorTokens)
        let confidence = adjustedConfidence(
            baseConfidence: baseConfidence,
            sectionType: sectionType,
            positiveFlags: positiveFlags,
            negativeFlags: negativeFlags,
            isVisible: isVisible
        )
        let anchorQualityScore = anchorQuality(
            sectionType: sectionType,
            positiveFlags: positiveFlags,
            negativeFlags: negativeFlags,
            distanceToTitle: distanceToTitle,
            distanceToBuyButton: distanceToBuyButton,
            isVisible: isVisible,
            sameAmountNodeCount: sameAmountNodeCount,
            rawText: rawText
        )

        return PriceCandidate(
            amount: amount,
            currency: currency,
            sourceType: sourceType,
            origin: origin,
            rawText: rawText,
            normalizedText: normalizedText,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            domPath: domPath(for: element),
            tagName: element.tagName().lowercased(),
            elementId: element.id(),
            classNames: classNames,
            ancestorTokens: ancestorTokens,
            isVisible: isVisible,
            boundingRect: nil,
            top: nil,
            left: nil,
            width: nil,
            height: nil,
            distanceToTitle: distanceToTitle,
            distanceToBuyButton: distanceToBuyButton,
            distanceToCartArea: distanceToBuyButton,
            isAboveTheFold: false,
            negativeContextFlags: negativeFlags,
            positiveContextFlags: positiveFlags,
            sectionType: sectionType,
            confidence: confidence,
            debugReasons: [
                "origin:\(origin.debugName)",
                "source:\(sourceType.debugName)"
            ],
            sameAmountNodeCount: sameAmountNodeCount,
            anchorQualityScore: anchorQualityScore
        )
    }

    private func elements(
        matching result: PriceResult,
        sourceType: PriceCandidateSourceType
    ) -> [Element] {
        let amountDigits = digitsOnly((result.price as NSDecimalNumber).stringValue)
        guard !amountDigits.isEmpty else { return [] }

        let selectors: [String]
        switch sourceType {
        case .dataAttribute:
            selectors = [
                "[data-price]",
                "[data-product-price]",
                "[data-sale-price]",
                "[data-amount]",
                "[data-tax-price]",
                "[data-taxed-price]",
                "[data-shade-tax-price]",
                PriceHeuristics.rawCandidateSelector
            ]
        case .contextual:
            selectors = [
                "tr", "dl", "dd", "td", PriceHeuristics.rawCandidateSelector
            ]
        default:
            selectors = [PriceHeuristics.rawCandidateSelector]
        }

        var seenPaths = Set<String>()
        var matched: [(element: Element, score: Double)] = []

        for selector in selectors {
            guard let elements = try? document.select(selector).array() else { continue }

            for element in elements {
                let text = truncated((try? element.text()) ?? "", limit: 240)
                guard !text.isEmpty else { continue }

                let textDigits = digitsOnly(text)
                guard textDigits.contains(amountDigits) else { continue }

                let path = domPath(for: element)
                guard !seenPaths.contains(path) else { continue }
                seenPaths.insert(path)

                let elementScore = preliminaryMatchScore(
                    text: text,
                    amountDigits: amountDigits,
                    sourceType: sourceType,
                    element: element
                )

                matched.append((element, elementScore))
            }
        }

        return matched
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return domPath(for: lhs.element) < domPath(for: rhs.element)
            }
            .prefix(14)
            .map(\.element)
    }

    private func preliminaryMatchScore(
        text: String,
        amountDigits: String,
        sourceType: PriceCandidateSourceType,
        element: Element
    ) -> Double {
        let normalizedText = normalized(text)
        let ancestorTokens = collectAncestorTokens(startingAt: element)
        let sectionType = inferSectionType(from: ancestorTokens)
        let positiveFlags = matchedFlags(in: normalizedText + " " + ancestorTokens.joined(separator: " "), tokens: PriceHeuristics.positiveContextTokens)
        let negativeFlags = matchedFlags(in: normalizedText + " " + ancestorTokens.joined(separator: " "), tokens: PriceHeuristics.negativeContextTokens + PriceHeuristics.sectionNegativeTokens)
        let distanceToTitle = nearestDOMDistance(from: element, toAny: referenceSignals.titleElements) ?? 999
        let distanceToBuy = nearestDOMDistance(from: element, toAny: referenceSignals.buyButtonElements) ?? 999
        let textDigits = digitsOnly(text)

        var score = 0.2
        score += textDigits == amountDigits ? 0.25 : 0.08
        score += min(Double(positiveFlags.count) * 0.06, 0.18)
        score -= min(Double(negativeFlags.count) * 0.08, 0.32)
        score += sourceType == .contextual ? 0.10 : 0
        score += scoreFor(sectionType: sectionType)
        score += distanceToTitle <= 4 ? 0.16 : distanceToTitle <= 8 ? 0.06 : 0
        score += distanceToBuy <= 4 ? 0.16 : distanceToBuy <= 8 ? 0.06 : 0
        if text.count <= 36 {
            score += 0.05
        }
        return score
    }

    private func scoreFor(sectionType: PriceSectionType) -> Double {
        switch sectionType {
        case .mainProduct:
            return 0.20
        case .buybox:
            return 0.24
        case .campaign, .shipping, .review, .recommendation, .related, .ranking, .breadcrumb, .gallery:
            return -0.22
        case .unknown:
            return 0
        }
    }

    private func adjustedConfidence(
        baseConfidence: Double,
        sectionType: PriceSectionType,
        positiveFlags: [String],
        negativeFlags: [String],
        isVisible: Bool
    ) -> Double {
        var confidence = baseConfidence
        confidence += min(Double(positiveFlags.count) * 0.02, 0.08)
        confidence -= min(Double(negativeFlags.count) * 0.03, 0.12)
        if isVisible {
            confidence += 0.02
        }

        switch sectionType {
        case .mainProduct, .buybox:
            confidence += 0.03
        case .campaign, .shipping, .review, .recommendation, .related, .ranking, .breadcrumb, .gallery:
            confidence -= 0.08
        case .unknown:
            break
        }

        return min(0.99, max(0.05, confidence))
    }

    private func anchorQuality(
        sectionType: PriceSectionType,
        positiveFlags: [String],
        negativeFlags: [String],
        distanceToTitle: Double?,
        distanceToBuyButton: Double?,
        isVisible: Bool,
        sameAmountNodeCount: Int,
        rawText: String
    ) -> Double {
        var score = 0.18
        if isVisible {
            score += 0.08
        }
        if let distanceToTitle, distanceToTitle <= 4 {
            score += 0.20
        } else if let distanceToTitle, distanceToTitle <= 8 {
            score += 0.10
        }
        if let distanceToBuyButton, distanceToBuyButton <= 4 {
            score += 0.20
        } else if let distanceToBuyButton, distanceToBuyButton <= 8 {
            score += 0.10
        }
        score += min(Double(positiveFlags.count) * 0.03, 0.12)
        score -= min(Double(negativeFlags.count) * 0.05, 0.25)
        if rawText.count <= 32 {
            score += 0.05
        }
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

    private func inferSectionType(from ancestorTokens: [String]) -> PriceSectionType {
        let combined = ancestorTokens.joined(separator: " ")
        for (sectionType, tokens) in PriceHeuristics.sectionMapping {
            if tokens.contains(where: combined.contains) {
                return sectionType
            }
        }
        return .unknown
    }

    private func matchedFlags(in value: String, tokens: [String]) -> [String] {
        var matched: [String] = []
        for token in tokens where value.contains(token) && !matched.contains(token) {
            matched.append(token)
        }
        return matched
    }

    private func isLikelyVisible(element: Element, ancestorTokens: [String]) -> Bool {
        if ((try? element.attr("hidden")) ?? "").isEmpty == false {
            return false
        }

        let hiddenTokens = ["hidden", "sr-only", "screen-reader", "visually-hidden", "aria-hidden"]
        return hiddenTokens.allSatisfy { token in
            !ancestorTokens.contains(where: { $0.contains(token) })
        }
    }

    private func nearestDOMDistance(from element: Element, toAny targets: [Element]) -> Double? {
        guard !targets.isEmpty else { return nil }
        let distances = targets.compactMap { domDistance(from: element, to: $0) }
        guard let distance = distances.min() else { return nil }
        return Double(distance)
    }

    private func domDistance(from lhs: Element, to rhs: Element) -> Int? {
        let lhsPath = ancestorPath(for: lhs)
        let rhsPath = ancestorPath(for: rhs)
        guard !lhsPath.isEmpty, !rhsPath.isEmpty else { return nil }

        let rhsLookup = Dictionary(uniqueKeysWithValues: rhsPath.enumerated().map { (offset, element) in
            (ObjectIdentifier(element), offset)
        })

        for (lhsIndex, lhsNode) in lhsPath.enumerated() {
            if let rhsIndex = rhsLookup[ObjectIdentifier(lhsNode)] {
                return lhsIndex + rhsIndex
            }
        }

        return nil
    }

    private func ancestorPath(for element: Element) -> [Element] {
        var path: [Element] = []
        var current: Element? = element
        while let node = current {
            path.append(node)
            current = node.parent()
        }
        return path
    }

    private func collectAncestorTokens(startingAt element: Element) -> [String] {
        var tokens: [String] = []
        var current: Element? = element
        var depth = 0

        while let node = current, depth < 7 {
            tokens.append(node.tagName().lowercased())
            tokens.append(contentsOf: tokenFragments(from: node.id()))
            tokens.append(contentsOf: tokenFragments(from: (try? node.className()) ?? ""))
            tokens.append(contentsOf: tokenFragments(from: (try? node.attr("aria-label")) ?? ""))
            tokens.append(contentsOf: tokenFragments(from: (try? node.attr("data-testid")) ?? ""))
            tokens.append(contentsOf: tokenFragments(from: (try? node.attr("role")) ?? ""))
            current = node.parent()
            depth += 1
        }

        return uniqueStrings(tokens.compactMap {
            let normalized = normalized($0)
            return normalized.isEmpty ? nil : normalized
        })
    }

    private func tokenFragments(from value: String) -> [String] {
        let normalizedValue = normalized(value)
        guard !normalizedValue.isEmpty else { return [] }

        let separators = CharacterSet.alphanumerics.inverted
        let components = normalizedValue
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }

        if components.isEmpty {
            return [normalizedValue]
        }

        return uniqueStrings(components + [normalizedValue])
    }

    private func normalizedClassNames(from rawValue: String) -> [String] {
        normalized(rawValue)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func normalized(_ value: String) -> String {
        PriceDocumentSignals.normalized(value)
    }

    private func digitsOnly(_ value: String) -> String {
        value.filter(\.isNumber)
    }

    private func truncated(_ value: String, limit: Int) -> String {
        String(value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func domPath(for element: Element) -> String {
        var segments: [String] = []
        var current: Element? = element

        while let node = current, node.tagName().lowercased() != "#root" {
            let tag = node.tagName().lowercased()
            let index = nthOfType(for: node)
            segments.append("\(tag):nth-of-type(\(index))")
            current = node.parent()
            if tag == "html" {
                break
            }
        }

        return segments.reversed().joined(separator: " > ")
    }

    private func nthOfType(for element: Element) -> Int {
        guard let parent = element.parent(),
              let children = try? parent.children().array() else {
            return 1
        }

        let tagName = element.tagName()
        var index = 0
        for child in children {
            if child.tagName() == tagName {
                index += 1
            }
            if child === element {
                return max(index, 1)
            }
        }

        return 1
    }

    private func deduplicated(_ candidates: [PriceCandidate]) -> [PriceCandidate] {
        var seen = Set<String>()
        var unique: [PriceCandidate] = []

        for candidate in candidates {
            let key = "\(candidate.amountKey)|\(candidate.anchorKey)|\(candidate.sourceType.rawValue)|\(candidate.origin.rawValue)"
            if seen.insert(key).inserted {
                unique.append(candidate)
            }
        }

        return unique
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for value in values where seen.insert(value).inserted {
            unique.append(value)
        }
        return unique
    }

    private func siblingText(of element: Element, previous: Bool) -> String {
        let sibling: Element?
        if previous {
            sibling = try? element.previousElementSibling()
        } else {
            sibling = try? element.nextElementSibling()
        }
        guard let sibling else { return "" }
        return (try? sibling.text()) ?? ""
    }
}
