// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct PageMetadata {
    let title: String?
    let resolvedUrl: String?
    let imageUrl: String?
    let productIdHints: [String]
}

struct MetadataExtractor: Sendable {

    func extract(from html: String, requestUrl: URL) -> PageMetadata {
        guard let document = try? SwiftSoup.parse(html) else {
            return PageMetadata(title: nil, resolvedUrl: nil, imageUrl: nil, productIdHints: [])
        }

        let title = extractTitle(from: document)
        let resolvedUrl = extractResolvedURL(from: document)
        let imageUrl = extractImageURL(from: document)
        let productIdHints = extractProductIDHints(from: document)

        return PageMetadata(
            title: title,
            resolvedUrl: resolvedUrl,
            imageUrl: imageUrl,
            productIdHints: productIdHints
        )
    }

    // MARK: - Title

    private func extractTitle(from document: Document) -> String? {
        // Prefer og:title meta tag
        if let ogTitle = metaContent(in: document, property: "og:title"),
           !ogTitle.isEmpty {
            return ogTitle
        }
        // Fall back to <title> tag
        if let titleText = try? document.title(), !titleText.isEmpty {
            return titleText
        }
        return nil
    }

    // MARK: - Resolved URL

    private func extractResolvedURL(from document: Document) -> String? {
        // Prefer canonical link tag
        if let canonical = try? document.select("link[rel='canonical']").first(),
           let href = try? canonical.attr("href"),
           !href.isEmpty,
           isAbsoluteURL(href) {
            return href
        }

        // Fall back to og:url meta tag
        if let ogURL = metaContent(in: document, property: "og:url"),
           !ogURL.isEmpty,
           isAbsoluteURL(ogURL) {
            return ogURL
        }

        return nil
    }

    // MARK: - Image URL

    private func extractImageURL(from document: Document) -> String? {
        guard let url = metaContent(in: document, property: "og:image"),
              !url.isEmpty,
              isAbsoluteURL(url) else { return nil }
        return url
    }

    // MARK: - Product ID Hints

    private func extractProductIDHints(from document: Document) -> [String] {
        guard let scripts = try? document.select("script[type='application/ld+json']") else {
            return []
        }

        var hints: [String] = []
        let hintKeys = ["sku", "gtin", "mpn", "productID"]

        for script in scripts {
            guard let jsonText = try? script.html(),
                  let data = jsonText.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }

            if let dict = raw as? [String: Any] {
                hints.append(contentsOf: extractHints(from: dict, keys: hintKeys))
            } else if let array = raw as? [[String: Any]] {
                for item in array {
                    hints.append(contentsOf: extractHints(from: item, keys: hintKeys))
                }
            }
        }

        return hints
    }

    private func extractHints(from dict: [String: Any], keys: [String]) -> [String] {
        var hints: [String] = []
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                hints.append(value)
            }
        }
        return hints
    }

    // MARK: - Helpers

    private func metaContent(in document: Document, property: String) -> String? {
        guard let element = try? document.select("meta[property='\(property)']").first() else {
            return nil
        }
        return try? element.attr("content")
    }

    private func isAbsoluteURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }
}
