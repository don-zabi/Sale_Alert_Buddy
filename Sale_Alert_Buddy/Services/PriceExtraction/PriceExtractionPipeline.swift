// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct PriceExtractionPipeline: Sendable {

    private let extractors: [any PriceExtractor]

    nonisolated init() {
        extractors = [
            SchemaOrgExtractor(),
            MetaTagExtractor(),
            DataAttributeExtractor(),
            EmbeddedJSONExtractor(),
            ContextualPriceExtractor(),
            HTMLPatternExtractor()
        ]
    }

    /// Parses the HTML string and runs each extractor.
    /// Returns the strongest consensus candidate after validation.
    nonisolated func extract(from html: String) -> (result: PriceResult, method: ExtractMethod)? {
        guard !html.isEmpty,
              let document = try? SwiftSoup.parse(html) else {
            return nil
        }

        let signalScorer = VisiblePriceSignalScorer(document: document)
        let validCandidates = extractors.flatMap { extractor in
            extractor.extract(from: document).filter { PriceValidator.validate($0) }
        }

        guard !validCandidates.isEmpty else {
            return nil
        }

        let grouped = Dictionary(grouping: validCandidates) {
            "\($0.currency.uppercased())|\($0.price)"
        }

        let rankedGroups = grouped.values.compactMap { group -> RankedCandidateGroup? in
            guard let representative = group.max(by: { $0.confidence < $1.confidence }) else {
                return nil
            }

            let uniqueMethods = Set(group.map(\.extractMethod))
            let visibilityScore = signalScorer.score(for: representative)
            let visibleMethodCount = uniqueMethods.filter(Self.isVisibleMethod).count
            let structuredMethodCount = uniqueMethods.filter(Self.isStructuredMethod).count
            let authoritativeMethodCount = uniqueMethods.filter(Self.isAuthoritativeMethod).count

            var score = representative.confidence
                + visibilityScore
                + (Double(visibleMethodCount) * 0.16)
                + (Double(structuredMethodCount) * 0.07)
                + (Double(authoritativeMethodCount) * 0.18)
                + (Double(group.count - uniqueMethods.count) * 0.02)

            if visibleMethodCount > 0 && visibilityScore >= 0.22 {
                score += 0.10
            }
            if visibleMethodCount == 0 && authoritativeMethodCount == 0 && visibilityScore <= 0.05 {
                score -= 0.10
            }

            return RankedCandidateGroup(
                representative: representative,
                score: score,
                visibleMethodCount: visibleMethodCount,
                methodCount: uniqueMethods.count,
                visibilityScore: visibilityScore
            )
        }

        guard let best = rankedGroups.max(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.visibilityScore != rhs.visibilityScore { return lhs.visibilityScore < rhs.visibilityScore }
            if lhs.visibleMethodCount != rhs.visibleMethodCount { return lhs.visibleMethodCount < rhs.visibleMethodCount }
            if lhs.methodCount != rhs.methodCount { return lhs.methodCount < rhs.methodCount }
            return lhs.representative.confidence < rhs.representative.confidence
        }) else {
            return nil
        }

        return (result: best.representative, method: best.representative.extractMethod)
    }
}

private struct RankedCandidateGroup {
    let representative: PriceResult
    let score: Double
    let visibleMethodCount: Int
    let methodCount: Int
    let visibilityScore: Double
}

private extension PriceExtractionPipeline {
    nonisolated static func isVisibleMethod(_ method: ExtractMethod) -> Bool {
        switch method {
        case .htmlContext, .htmlPattern, .dataAttribute:
            return true
        default:
            return false
        }
    }

    nonisolated static func isStructuredMethod(_ method: ExtractMethod) -> Bool {
        switch method {
        case .schemaOrg, .metaTag, .embeddedJSON:
            return true
        default:
            return false
        }
    }

    nonisolated static func isAuthoritativeMethod(_ method: ExtractMethod) -> Bool {
        method == .siteAPI
    }
}
