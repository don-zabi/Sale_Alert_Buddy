// REQUIRES: SwiftSoup SPM package.
import Foundation
import SwiftSoup

/// Deterministic price extractor for Mercari item pages.
///
/// Mercari is a client-rendered SPA, so a raw server fetch usually has no price
/// and this resolver returns `nil` there — the caller then renders the page in a
/// WebView and re-runs the resolver against the hydrated DOM. On the rendered
/// DOM the price lives in a stable `data-testid="price"` node (historically a
/// `<mer-price value="3000">` web component). Server-rendered JSON-LD / meta
/// tags are used as secondary sources when present.
struct MercariPriceResolver: Sendable {

    nonisolated init() {}

    func resolve(for url: URL, html: String) -> PriceResult? {
        guard SupportedShop.from(url: url) == .mercari,
              !html.isEmpty,
              let document = try? SwiftSoup.parse(html) else {
            return nil
        }

        return priceFromTestIDNode(document)
            ?? priceFromMeta(document)
            ?? priceFromJSONLD(document)
    }

    // MARK: - Primary: rendered DOM price node

    private func priceFromTestIDNode(_ document: Document) -> PriceResult? {
        guard let elements = try? document.select("[data-testid=price]").array() else {
            return nil
        }

        for element in elements {
            // `mer-price` exposes the integer yen amount as a `value` attribute.
            if let value = try? element.attr("value"),
               let result = makeResult(digitsText: value) {
                return result
            }

            let text = (try? element.text()) ?? ""
            if let parsed = PriceCurrencyParser.parse(text), parsed.currency == "JPY" {
                return makeResult(price: parsed.price)
            }
            if let result = makeResult(digitsText: text.filter { $0.isNumber }) {
                return result
            }
        }

        return nil
    }

    // MARK: - Secondary: meta tags

    private func priceFromMeta(_ document: Document) -> PriceResult? {
        let selectors = [
            "meta[property=product:price:amount]",
            "meta[itemprop=price]",
            "meta[name=product:price:amount]"
        ]

        for selector in selectors {
            guard let element = try? document.select(selector).first(),
                  let content = try? element.attr("content") else { continue }
            if let result = makeResult(digitsText: content) {
                return result
            }
        }

        return nil
    }

    // MARK: - Secondary: JSON-LD offers

    private func priceFromJSONLD(_ document: Document) -> PriceResult? {
        guard let scripts = try? document.select("script[type=application/ld+json]").array() else {
            return nil
        }

        for script in scripts {
            guard let json = try? script.html(),
                  let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            if let result = offerPrice(in: root) {
                return result
            }
        }

        return nil
    }

    private func offerPrice(in node: Any) -> PriceResult? {
        if let dict = node as? [String: Any] {
            if let offers = dict["offers"] {
                if let result = offerPrice(in: offers) {
                    return result
                }
            }
            if let price = dict["price"],
               currencyIsJPY(dict["priceCurrency"]),
               let value = decimal(from: price) {
                return makeResult(price: value)
            }
            for value in dict.values {
                if let result = offerPrice(in: value) {
                    return result
                }
            }
        }

        if let array = node as? [Any] {
            for value in array {
                if let result = offerPrice(in: value) {
                    return result
                }
            }
        }

        return nil
    }

    private func currencyIsJPY(_ value: Any?) -> Bool {
        // Mercari JP omits currency in some payloads; treat missing as JPY.
        guard let currency = value as? String, !currency.isEmpty else { return true }
        return currency.uppercased() == "JPY"
    }

    // MARK: - Helpers

    private func decimal(from value: Any) -> Decimal? {
        switch value {
        case let number as NSNumber:
            return Decimal(string: number.stringValue)
        case let string as String:
            if let parsed = PriceCurrencyParser.parse(string), parsed.currency == "JPY" {
                return parsed.price
            }
            return Decimal(string: string.replacingOccurrences(of: ",", with: ""))
        default:
            return nil
        }
    }

    private func makeResult(digitsText: String) -> PriceResult? {
        let cleaned = digitsText
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let price = Decimal(string: cleaned) else { return nil }
        return makeResult(price: price)
    }

    private func makeResult(price: Decimal) -> PriceResult? {
        let result = PriceResult(
            price: price,
            currency: "JPY",
            extractMethod: .siteAPI,
            confidence: 0.98,
            confidenceLevel: .high,
            sourceType: .siteAPI
        )
        return PriceValidator.validate(result) ? result : nil
    }
}
