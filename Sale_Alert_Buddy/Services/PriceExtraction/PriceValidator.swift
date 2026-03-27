import Foundation

struct PriceValidator {

    /// Returns true if the PriceResult passes all validation rules.
    ///
    /// Rules:
    /// - Price must be > 0
    /// - Currency must not be empty
    /// - JPY: price must be <= 10,000,000
    /// - USD/EUR/GBP: price must be <= 100,000
    /// - Other currencies: no upper limit
    static func validate(_ result: PriceResult) -> Bool {
        guard result.price > 0 else { return false }
        guard !result.currency.isEmpty else { return false }

        switch result.currency {
        case "JPY":
            return result.price <= 10_000_000
        case "USD", "EUR", "GBP":
            return result.price <= 100_000
        default:
            return true
        }
    }
}
