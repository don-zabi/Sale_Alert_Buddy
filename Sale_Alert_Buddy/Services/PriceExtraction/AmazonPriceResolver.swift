// REQUIRES: SwiftSoup SPM package.
import Foundation
import SwiftSoup

/// Deterministic price extractor for Amazon product pages.
///
/// Amazon renders the authoritative buy-box price in a small, stable set of
/// containers, with the fully-formatted value inside a visually-hidden
/// `.a-offscreen` span (e.g. `￥1,980`). This resolver targets those containers
/// in priority order and deliberately ignores list/reference prices
/// (`.a-text-price`), used-item offers, "other sellers", and Subscribe & Save
/// pricing, which are the usual sources of wrong detections.
struct AmazonPriceResolver: Sendable {

    nonisolated init() {}

    /// Ordered price containers. The first container that yields a valid price wins.
    private static let priceContainerSelectors: [String] = [
        "#corePriceDisplay_desktop_feature_div",
        "#corePriceDisplay_mobile_feature_div",
        "#corePrice_feature_div",
        "#corePrice_desktop",
        "#corePrice_mobile_feature_div",
        "#apex_desktop",
        "#apex_mobile",
        "#qualifiedBuybox",
        "#buybox",
        "#tp_price_block_total_price_ww",
        "#newAccordionRow"
    ]

    /// Legacy elements that are themselves the price node.
    private static let legacyPriceSelectors: [String] = [
        "#priceblock_ourprice",
        "#priceblock_dealprice",
        "#priceblock_saleprice",
        "#priceblock_pospromoprice",
        "#price_inside_buybox",
        "#sns-base-price"
    ]

    /// Ancestor id/class tokens whose subtree must never contribute a price
    /// (used offers, other sellers, bundles, similarities, list price).
    private static let excludedAncestorTokens: [String] = [
        "usedbuysection", "aod", "olp", "unqualifiedbuybox",
        "similarities", "bundle", "sns", "subscribe", "renewedprogram"
    ]

    func resolve(for url: URL, html: String) -> PriceResult? {
        guard SupportedShop.from(url: url) == .amazon,
              !html.isEmpty,
              let document = try? SwiftSoup.parse(html) else {
            return nil
        }

        let hostCurrency = SupportedShop.amazon.currency(forHost: url.host)

        for selector in Self.priceContainerSelectors {
            guard let container = try? document.select(selector).first() else { continue }
            if let result = price(in: container, hostCurrency: hostCurrency) {
                return result
            }
        }

        for selector in Self.legacyPriceSelectors {
            guard let element = try? document.select(selector).first(),
                  !isExcluded(element) else { continue }
            if let result = parse(text(of: element), hostCurrency: hostCurrency) {
                return result
            }
        }

        return nil
    }

    // MARK: - Price Location

    private func price(in container: Element, hostCurrency: String) -> PriceResult? {
        // 1) Preferred: an active price block (not the struck-through list price),
        //    whose formatted value lives in `.a-offscreen`.
        if let priceBlocks = try? container.select("span.a-price:not(.a-text-price)").array() {
            for block in priceBlocks where !isExcluded(block) {
                if let offscreen = try? block.select("span.a-offscreen").first(),
                   let result = parse(text(of: offscreen), hostCurrency: hostCurrency) {
                    return result
                }
                if let result = wholeFractionPrice(in: block, hostCurrency: hostCurrency) {
                    return result
                }
            }
        }

        // 2) Any `.a-offscreen` in the container that isn't a list price.
        if let offscreens = try? container.select("span.a-offscreen").array() {
            for offscreen in offscreens where !isExcluded(offscreen) {
                if let result = parse(text(of: offscreen), hostCurrency: hostCurrency) {
                    return result
                }
            }
        }

        // 3) Whole/fraction fallback anywhere in the container.
        return wholeFractionPrice(in: container, hostCurrency: hostCurrency)
    }

    private func wholeFractionPrice(in element: Element, hostCurrency: String) -> PriceResult? {
        guard let whole = try? element.select("span.a-price-whole").first(),
              !isExcluded(whole) else {
            return nil
        }

        let wholeText = text(of: whole).filter { $0.isNumber || $0 == "," }
        guard !wholeText.isEmpty else { return nil }

        var combined = wholeText
        if let fraction = try? element.select("span.a-price-fraction").first() {
            let fractionText = text(of: fraction).filter(\.isNumber)
            if !fractionText.isEmpty {
                combined += "." + fractionText
            }
        }

        return makeResult(digitsText: combined, hostCurrency: hostCurrency)
    }

    // MARK: - Parsing

    private func parse(_ raw: String, hostCurrency: String) -> PriceResult? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Prefer the currency embedded in the formatted string (￥, $, £ …),
        // but only trust it when it agrees with the host's marketplace currency.
        if let parsed = PriceCurrencyParser.parse(trimmed) {
            let currency = parsed.currency == hostCurrency ? parsed.currency : hostCurrency
            return makeResult(price: parsed.price, currency: currency)
        }

        return makeResult(digitsText: trimmed, hostCurrency: hostCurrency)
    }

    private func makeResult(digitsText: String, hostCurrency: String) -> PriceResult? {
        let cleaned = digitsText.replacingOccurrences(of: ",", with: "")
        guard let price = Decimal(string: cleaned) else { return nil }
        return makeResult(price: price, currency: hostCurrency)
    }

    private func makeResult(price: Decimal, currency: String) -> PriceResult? {
        let result = PriceResult(
            price: price,
            currency: currency,
            extractMethod: .siteAPI,
            confidence: 0.98,
            confidenceLevel: .high,
            sourceType: .siteAPI
        )
        return PriceValidator.validate(result) ? result : nil
    }

    // MARK: - Helpers

    private func text(of element: Element) -> String {
        (try? element.text()) ?? ""
    }

    private func isExcluded(_ element: Element) -> Bool {
        var node: Element? = element
        var depth = 0
        while let current = node, depth < 12 {
            let token = (current.id() + " " + ((try? current.className()) ?? "")).lowercased()
            if Self.excludedAncestorTokens.contains(where: token.contains) {
                return true
            }
            node = current.parent()
            depth += 1
        }
        return false
    }
}
