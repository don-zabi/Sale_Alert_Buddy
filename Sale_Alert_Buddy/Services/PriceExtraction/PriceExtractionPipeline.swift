import Foundation
import SwiftSoup

struct PriceExtractionPipeline: Sendable {

    private let extractors: [any PriceExtractor]
    private let scorer = VisiblePriceSignalScorer()

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

    nonisolated func extract(from html: String) -> (result: PriceResult, method: ExtractMethod)? {
        guard let analysis = analyze(from: html, origin: .rawHTML),
              let best = analysis.bestCandidate else {
            return nil
        }

        let result = makeResult(
            from: best.candidate,
            confidenceLevel: confidenceLevel(
                for: best,
                runnerUp: analysis.rankedCandidates.dropFirst().first
            )
        )
        return (result, result.extractMethod)
    }

    nonisolated func analyze(
        from html: String,
        origin: PriceCandidateOrigin,
        additionalCandidates: [PriceCandidate] = [],
        isProtectionPage: Bool = false
    ) -> PriceSourceAnalysis? {
        let meaningfulContent = hasMeaningfulContent(in: html)

        if html.isEmpty {
            guard !additionalCandidates.isEmpty else { return nil }
            let ranked = scorer.rank(additionalCandidates)
            return PriceSourceAnalysis(
                origin: origin,
                candidates: additionalCandidates,
                rankedCandidates: ranked,
                bestCandidate: ranked.first,
                isProtectionPage: isProtectionPage,
                hasMeaningfulContent: meaningfulContent
            )
        }

        guard let document = try? SwiftSoup.parse(html) else {
            guard !additionalCandidates.isEmpty else { return nil }
            let ranked = scorer.rank(additionalCandidates)
            return PriceSourceAnalysis(
                origin: origin,
                candidates: additionalCandidates,
                rankedCandidates: ranked,
                bestCandidate: ranked.first,
                isProtectionPage: isProtectionPage,
                hasMeaningfulContent: meaningfulContent
            )
        }

        let builder = PriceCandidateBuilder(document: document, origin: origin)
        let extractedCandidates = extractors
            .flatMap { extractor in
                extractor.extract(from: document)
                    .filter { PriceValidator.validate($0) }
                    .flatMap { builder.expand(result: $0) }
            }

        let candidates = deduplicated(extractedCandidates + additionalCandidates)
        guard !candidates.isEmpty else { return nil }

        let ranked = scorer.rank(candidates)
        return PriceSourceAnalysis(
            origin: origin,
            candidates: candidates,
            rankedCandidates: ranked,
            bestCandidate: ranked.first,
            isProtectionPage: isProtectionPage,
            hasMeaningfulContent: meaningfulContent
        )
    }

    nonisolated func makeResult(
        from candidate: PriceCandidate,
        confidenceLevel: PriceConfidenceLevel
    ) -> PriceResult {
        PriceResult(
            price: candidate.amount,
            currency: candidate.currency,
            extractMethod: candidate.extractMethod,
            confidence: candidate.confidence,
            confidenceLevel: confidenceLevel,
            sourceType: candidate.sourceType,
            anchor: candidate.anchor
        )
    }

    private nonisolated func confidenceLevel(
        for best: ScoredPriceCandidate,
        runnerUp: ScoredPriceCandidate?
    ) -> PriceConfidenceLevel {
        let gap = best.score - (runnerUp?.score ?? -1)
        let candidate = best.candidate
        let missingPrimarySignal = !candidate.hasPrimarySignal && !candidate.hasAuthoritativeSource

        if candidate.sourceType == .siteAPI {
            return .high
        }

        if candidate.hasPrimarySignal &&
            !candidate.hasSevereNegativeSignal &&
            gap >= 0.18 &&
            (candidate.isVisible || candidate.sectionType == .mainProduct || candidate.sectionType == .buybox) {
            return .high
        }

        if candidate.hasAuthoritativeSource &&
            !candidate.hasSevereNegativeSignal &&
            gap >= 0.14 {
            return .medium
        }

        if gap < 0.08 ||
            candidate.hasSevereNegativeSignal ||
            missingPrimarySignal ||
            candidate.sameAmountNodeCount > 6 {
            return .low
        }

        return .medium
    }

    private nonisolated func hasMeaningfulContent(in html: String) -> Bool {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count > 400 {
            return true
        }
        let lowered = trimmed.lowercased()
        if lowered.contains("application/ld+json") ||
            lowered.contains("\"pricecurrency\"") ||
            lowered.contains("\"price\"") ||
            lowered.contains("og:image") ||
            lowered.contains("<title>") {
            return true
        }
        return lowered.contains("<img") || lowered.contains("<main") || lowered.contains("<article") || lowered.contains("<section")
    }

    private nonisolated func deduplicated(_ candidates: [PriceCandidate]) -> [PriceCandidate] {
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
}
