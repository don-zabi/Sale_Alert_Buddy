import Foundation

struct PriceResult: Sendable {
    let price: Decimal
    let currency: String
    let extractMethod: ExtractMethod
    let confidence: Double

    var isValid: Bool {
        price > 0 && !currency.isEmpty
    }
}
