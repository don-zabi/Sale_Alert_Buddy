// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct SchemaOrgExtractor: PriceExtractor {

    func extract(from document: Document) -> [PriceResult] {
        guard let scripts = try? document.select("script[type='application/ld+json']") else {
            return []
        }

        var results: [PriceResult] = []

        for script in scripts {
            guard let jsonText = try? script.html(),
                  let data = jsonText.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }

            if let dict = raw as? [String: Any] {
                results.append(contentsOf: extractFromObject(dict))
            } else if let array = raw as? [[String: Any]] {
                for item in array {
                    results.append(contentsOf: extractFromObject(item))
                }
            }
        }

        return results
    }

    // MARK: - Private Helpers

    private func extractFromObject(_ dict: [String: Any]) -> [PriceResult] {
        var results: [PriceResult] = []

        // Handle @graph array — recurse into each node
        if let graph = dict["@graph"] as? [[String: Any]] {
            for node in graph {
                results.append(contentsOf: extractFromObject(node))
            }
            return results
        }

        let type_ = dict["@type"] as? String ?? ""

        if type_ == "Product" {
            // Try nested offers
            if let offersDict = dict["offers"] as? [String: Any] {
                results.append(contentsOf: extractFromOfferObject(offersDict))
            } else if let offersArray = dict["offers"] as? [[String: Any]] {
                for offer in offersArray {
                    results.append(contentsOf: extractFromOfferObject(offer))
                }
            }
        } else if type_ == "Offer" || type_ == "AggregateOffer" {
            results.append(contentsOf: extractFromOfferObject(dict))
        }

        return results
    }

    private func extractFromOfferObject(_ offer: [String: Any]) -> [PriceResult] {
        let type_ = offer["@type"] as? String ?? ""
        var results: [PriceResult] = []

        // Determine currency
        let currency = offer["priceCurrency"] as? String

        // For AggregateOffer use lowPrice; for Offer use price
        if type_ == "AggregateOffer" {
            if let result = extractPrice(from: offer, key: "lowPrice", currency: currency) {
                results.append(result)
            }
        } else {
            if let result = extractPrice(from: offer, key: "price", currency: currency) {
                results.append(result)
            }
        }

        // Always try both keys if the primary didn't work
        if results.isEmpty {
            if let result = extractPrice(from: offer, key: "price", currency: currency) {
                results.append(result)
            }
            if let result = extractPrice(from: offer, key: "lowPrice", currency: currency) {
                results.append(result)
            }
        }

        return results
    }

    private func extractPrice(
        from dict: [String: Any],
        key: String,
        currency: String?
    ) -> PriceResult? {
        let priceDecimal: Decimal?
        var resolvedCurrency = currency

        if let priceStr = dict[key] as? String {
            // Price as string — may include currency symbol
            if let parsed = PriceCurrencyParser.parse(priceStr) {
                priceDecimal = parsed.price
                if resolvedCurrency == nil {
                    resolvedCurrency = parsed.currency
                }
            } else {
                // Try parsing as plain number string
                priceDecimal = Decimal(string: priceStr)
            }
        } else if let priceNum = dict[key] as? Double {
            // Use string conversion to preserve the human-readable value.
            // Decimal(Double) encodes the exact IEEE 754 representation, which
            // loses precision: Decimal(19.99) → 19.9900000000000002131...
            priceDecimal = Decimal(string: String(priceNum))
        } else if let priceNum = dict[key] as? Int {
            priceDecimal = Decimal(priceNum)
        } else {
            return nil
        }

        guard let price = priceDecimal, let curr = resolvedCurrency, !curr.isEmpty else {
            return nil
        }

        return PriceResult(
            price: price,
            currency: curr,
            extractMethod: .schemaOrg,
            confidence: 0.95
        )
    }
}
