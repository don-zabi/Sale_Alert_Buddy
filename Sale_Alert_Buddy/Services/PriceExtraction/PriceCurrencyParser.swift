import Foundation

/// Parses a text string to extract a price and its ISO 4217 currency code.
///
/// Supports the following formats:
/// - JPY: "1,980円", "¥1,980", "￥1,980", "1980円"
/// - USD: "$19.99", "USD 19.99", "19.99 USD"
/// - EUR: "€29.99", "EUR 29.99", "29,99 EUR", "29.99 EUR"
/// - GBP: "£19.99", "GBP 19.99"
struct PriceCurrencyParser {

    static func parse(_ text: String) -> (price: Decimal, currency: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Try each currency strategy in order
        if let result = parseJPY(trimmed) { return result }
        if let result = parseSymbolCurrency(trimmed) { return result }
        if let result = parseCodeCurrency(trimmed) { return result }

        return nil
    }

    // MARK: - JPY

    private static func parseJPY(_ text: String) -> (price: Decimal, currency: String)? {
        // Matches: ¥1,980 | ￥1,980 | 1,980円 | 1980円 | ¥1980
        let pattern = #"[¥￥]([\d,]+)|([\d,]+)円"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }

        // Group 1: ¥ prefix form, Group 2: 円 suffix form
        let digits: String
        if let g1 = Range(match.range(at: 1), in: text) {
            digits = String(text[g1])
        } else if let g2 = Range(match.range(at: 2), in: text) {
            digits = String(text[g2])
        } else {
            return nil
        }

        let cleaned = digits.replacingOccurrences(of: ",", with: "")
        guard let price = Decimal(string: cleaned) else { return nil }
        return (price, "JPY")
    }

    // MARK: - Symbol-based currencies (USD, EUR, GBP)

    private static func parseSymbolCurrency(_ text: String) -> (price: Decimal, currency: String)? {
        // Matches currency symbol followed by a number
        // Symbols: $ USD, € EUR, £ GBP
        let pattern = #"([$€£])\s*([\d,]+(?:[.,]\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }

        guard let symbolRange = Range(match.range(at: 1), in: text),
              let amountRange = Range(match.range(at: 2), in: text) else { return nil }

        let symbol = String(text[symbolRange])
        let rawAmount = String(text[amountRange])

        guard let currency = currencyForSymbol(symbol),
              let price = parseAmount(rawAmount, currency: currency) else { return nil }

        return (price, currency)
    }

    // MARK: - Code-based currencies (USD, EUR, GBP)

    private static func parseCodeCurrency(_ text: String) -> (price: Decimal, currency: String)? {
        let codes = ["USD", "EUR", "GBP"]
        for code in codes {
            if let result = parseCurrencyCode(code, in: text) {
                return result
            }
        }
        return nil
    }

    private static func parseCurrencyCode(_ code: String, in text: String) -> (price: Decimal, currency: String)? {
        // Try code-prefix form: "USD 19.99"
        let prefixPattern = #"(?:^|(?<=\s))"# + code + #"\s*([\d,]+(?:[.,]\d+)?)(?:\s|$)"#
        if let regex = try? NSRegularExpression(pattern: prefixPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let g1 = Range(match.range(at: 1), in: text) {
            let rawAmount = String(text[g1])
            if let price = parseAmount(rawAmount, currency: code) {
                return (price, code)
            }
        }

        // Try number-suffix form: "19.99 USD"
        let suffixPattern = #"([\d,]+(?:[.,]\d+)?)\s*"# + code + #"(?:\s|$)"#
        if let regex = try? NSRegularExpression(pattern: suffixPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let g1 = Range(match.range(at: 1), in: text) {
            let rawAmount = String(text[g1])
            if let price = parseAmount(rawAmount, currency: code) {
                return (price, code)
            }
        }

        return nil
    }

    // MARK: - Helpers

    private static func currencyForSymbol(_ symbol: String) -> String? {
        switch symbol {
        case "$": return "USD"
        case "€": return "EUR"
        case "£": return "GBP"
        default: return nil
        }
    }

    /// Parses an amount string to Decimal.
    ///
    /// For JPY: commas are thousands separators, no decimal point.
    /// For EUR with European format (e.g. "29,99"): treats trailing comma+2 digits as decimal.
    /// For USD/GBP: period is decimal separator, comma is thousands separator.
    private static func parseAmount(_ raw: String, currency: String) -> Decimal? {
        // Detect European decimal format: exactly two digits after the final comma
        // and no period present — e.g. "29,99" means 29.99
        let isEuropeanDecimal: Bool
        if currency == "EUR" || currency == "GBP" {
            // Check if last separator is a comma followed by exactly 2 digits
            let parts = raw.components(separatedBy: ",")
            if parts.count == 2 && parts[1].count == 2 && !raw.contains(".") {
                isEuropeanDecimal = true
            } else {
                isEuropeanDecimal = false
            }
        } else {
            isEuropeanDecimal = false
        }

        let normalized: String
        if isEuropeanDecimal {
            // "29,99" → "29.99"
            normalized = raw.replacingOccurrences(of: ",", with: ".")
        } else {
            // Remove thousands commas, keep decimal period
            normalized = raw.replacingOccurrences(of: ",", with: "")
        }

        return Decimal(string: normalized)
    }
}
