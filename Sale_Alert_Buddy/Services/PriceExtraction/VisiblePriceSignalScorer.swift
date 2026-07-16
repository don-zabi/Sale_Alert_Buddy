import Foundation

struct VisiblePriceSignalScorer {

    func rank(_ candidates: [PriceCandidate]) -> [ScoredPriceCandidate] {
        let amountSupport = Dictionary(grouping: candidates, by: \.amountKey)

        return candidates
            .map { candidate in
                let related = amountSupport[candidate.amountKey] ?? [candidate]
                return score(candidate, relatedCandidates: related)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.anchorScore != rhs.anchorScore {
                    return lhs.anchorScore > rhs.anchorScore
                }
                if lhs.candidate.confidence != rhs.candidate.confidence {
                    return lhs.candidate.confidence > rhs.candidate.confidence
                }
                return lhs.candidate.anchorKey < rhs.candidate.anchorKey
            }
    }

    private func score(
        _ candidate: PriceCandidate,
        relatedCandidates: [PriceCandidate]
    ) -> ScoredPriceCandidate {
        var score = candidate.confidence
        var adoptionReasons: [String] = []
        var rejectionReasons: [String] = []

        let distinctOrigins = Set(relatedCandidates.map(\.origin))
        let distinctSourceTypes = Set(relatedCandidates.map(\.sourceType))

        let sourceBonus = sourceScore(for: candidate.sourceType)
        score += sourceBonus
        if sourceBonus > 0 {
            adoptionReasons.append("source+\(candidate.sourceType.debugName)")
        }

        let sectionBonus = sectionScore(for: candidate.sectionType)
        score += sectionBonus
        if sectionBonus > 0 {
            adoptionReasons.append("section+\(candidate.sectionType.rawValue)")
        } else if sectionBonus < 0 {
            rejectionReasons.append("section-\(candidate.sectionType.rawValue)")
        }

        if candidate.isVisible {
            score += 0.18
            adoptionReasons.append("visible")
        }

        if candidate.isAboveTheFold {
            score += 0.15
            adoptionReasons.append("above-fold")
        }

        if candidate.isNearTitle {
            score += 0.22
            adoptionReasons.append("near-title")
        }

        if candidate.isNearBuyButton {
            score += 0.24
            adoptionReasons.append("near-buy")
        }

        let anchorContribution = candidate.anchorQualityScore * 0.30
        score += anchorContribution
        if anchorContribution >= 0.08 {
            adoptionReasons.append("anchor-quality")
        }

        if let fontSize = candidate.fontSize {
            if fontSize >= 24 {
                score += 0.14
                adoptionReasons.append("font-large")
            } else if fontSize >= 18 {
                score += 0.08
                adoptionReasons.append("font-medium")
            }
        }

        if let fontWeight = candidate.fontWeight, fontWeight >= 600 {
            score += 0.04
        }

        if containsCurrencyMarker(candidate.rawText) {
            score += 0.08
            adoptionReasons.append("currency-marker")
        }

        let positivePenaltySafeCount = candidate.negativeContextFlags.isEmpty ? candidate.positiveContextFlags.count : max(candidate.positiveContextFlags.count - 1, 0)
        if positivePenaltySafeCount > 0 {
            score += min(Double(positivePenaltySafeCount) * 0.05, 0.22)
            adoptionReasons.append("positive-context")
        }

        if !candidate.negativeContextFlags.isEmpty {
            let negativePenalty = min(Double(candidate.negativeContextFlags.count) * 0.12, 0.60)
            score -= negativePenalty
            rejectionReasons.append("negative-context")
        }

        if candidate.hasSevereNegativeSignal {
            score -= 0.14
            rejectionReasons.append("severe-negative")
        }

        if candidate.sameAmountNodeCount > 4 {
            let duplicatePenalty = min(Double(candidate.sameAmountNodeCount - 4) * 0.03, 0.22)
            score -= duplicatePenalty
            rejectionReasons.append("duplicate-anchors")
        }

        if distinctSourceTypes.count >= 2 {
            score += 0.08
            adoptionReasons.append("multi-source")
        }

        if distinctOrigins.count >= 2 {
            score += 0.14
            adoptionReasons.append("raw-render-consensus")
        }

        if candidate.origin == .renderedDOM {
            score += 0.12
            adoptionReasons.append("rendered-dom")
        } else if candidate.origin == .renderedHTML {
            score += 0.04
            adoptionReasons.append("rendered-html")
        }

        if !candidate.hasPrimarySignal {
            score -= 0.26
            rejectionReasons.append("missing-primary-signal")
        } else {
            adoptionReasons.append("primary-signal")
        }

        if candidate.hasSevereNegativeSignal && !candidate.hasPrimarySignal {
            score -= 0.24
            rejectionReasons.append("auxiliary-price-context")
        }

        return ScoredPriceCandidate(
            candidate: candidate,
            score: score,
            anchorScore: candidate.anchorQualityScore,
            adoptionReasons: adoptionReasons,
            rejectionReasons: rejectionReasons
        )
    }

    private func sourceScore(for sourceType: PriceCandidateSourceType) -> Double {
        switch sourceType {
        case .jsonld:
            return 0.18
        case .meta:
            return 0.14
        case .dataAttribute:
            return 0.10
        case .embeddedJson:
            return 0.12
        case .contextual:
            return 0.14
        case .htmlPattern:
            return 0.06
        case .renderedVisible:
            return 0.22
        case .siteAPI:
            return 0.34
        }
    }

    private func sectionScore(for sectionType: PriceSectionType) -> Double {
        switch sectionType {
        case .mainProduct:
            return 0.30
        case .buybox:
            return 0.34
        case .campaign:
            return -0.22
        case .shipping:
            return -0.26
        case .review:
            return -0.28
        case .recommendation:
            return -0.30
        case .related:
            return -0.30
        case .ranking:
            return -0.30
        case .breadcrumb:
            return -0.18
        case .gallery:
            return -0.12
        case .unknown:
            return 0
        }
    }

    private func containsCurrencyMarker(_ value: String) -> Bool {
        value.contains("¥") ||
        value.contains("￥") ||
        value.contains("円") ||
        value.contains("$") ||
        value.contains("€") ||
        value.contains("£")
    }
}

