import Foundation

struct PriceResult: Sendable {
    let price: Decimal
    let currency: String
    let extractMethod: ExtractMethod
    let confidence: Double
    let confidenceLevel: PriceConfidenceLevel
    let sourceType: PriceCandidateSourceType?
    let anchor: PriceAnchor?

    init(
        price: Decimal,
        currency: String,
        extractMethod: ExtractMethod,
        confidence: Double,
        confidenceLevel: PriceConfidenceLevel = .medium,
        sourceType: PriceCandidateSourceType? = nil,
        anchor: PriceAnchor? = nil
    ) {
        self.price = price
        self.currency = currency
        self.extractMethod = extractMethod
        self.confidence = confidence
        self.confidenceLevel = confidenceLevel
        self.sourceType = sourceType
        self.anchor = anchor
    }

    var isValid: Bool {
        price > 0 && !currency.isEmpty
    }
}
