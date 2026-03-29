// REQUIRES: SwiftSoup SPM package — add via Xcode > File > Add Package Dependencies > https://github.com/scinfu/SwiftSoup.git
import Foundation
import SwiftSoup

struct PageMetadata: Sendable {
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
        let imageUrl = extractImageURL(from: document, requestUrl: requestUrl)
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
        let titleKeys = ["og:title", "twitter:title"]
        for key in titleKeys {
            if let value = metaContent(in: document, property: key), !value.isEmpty {
                return value
            }
        }
        if let titleText = try? document.title(), !titleText.isEmpty {
            return titleText
        }
        return nil
    }

    // MARK: - Resolved URL

    private func extractResolvedURL(from document: Document) -> String? {
        if let canonical = try? document.select("link[rel='canonical']").first(),
           let href = try? canonical.attr("href"),
           !href.isEmpty,
           isAbsoluteURL(href) {
            return href
        }

        if let ogURL = metaContent(in: document, property: "og:url"),
           !ogURL.isEmpty,
           isAbsoluteURL(ogURL) {
            return ogURL
        }

        return nil
    }

    // MARK: - Image URL

    private func extractImageURL(from document: Document, requestUrl: URL) -> String? {
        // Standard Open Graph / Twitter meta tags (preferred by all sites)
        let imageKeys = ["og:image", "twitter:image", "twitter:image:src"]
        for key in imageKeys {
            if let url = metaContent(in: document, property: key),
               !url.isEmpty,
               isAbsoluteURL(url) {
                return url
            }
        }

        // Amazon-specific DOM fallback for pages where meta tags are absent
        if isAmazonHost(requestUrl.host ?? "") {
            return extractAmazonImageURL(from: document)
        }

        return nil
    }

    // MARK: - Amazon Image Extraction

    private func isAmazonHost(_ host: String) -> Bool {
        let h = host.lowercased()
        // Match amazon.*, amzn.*, and *.amazon.* domains
        return h.hasPrefix("www.amazon.") || h == "amazon.co.jp" || h == "amazon.com" ||
               h.hasPrefix("amazon.") || h.contains(".amazon.") || h.contains("amzn.")
    }

    /// Extracts the highest-resolution product image from Amazon's DOM.
    ///
    /// Strategy (in priority order):
    /// 1. `data-a-dynamic-image` attribute: JSON dict mapping URL → [width, height];
    ///    we pick the URL whose area (w × h) is largest.
    /// 2. `#landingImage` `src` attribute.
    /// 3. First `img` inside `#imgTagWrapperId`.
    private func extractAmazonImageURL(from document: Document) -> String? {
        // 1. data-a-dynamic-image — JSON: {"https://...": [w, h], ...}
        if let img = try? document.select("[data-a-dynamic-image]").first(),
           let jsonStr = try? img.attr("data-a-dynamic-image"),
           !jsonStr.isEmpty,
           let data = jsonStr.data(using: .utf8),
           let urlMap = try? JSONSerialization.jsonObject(with: data) as? [String: [Int]] {
            let best = urlMap.max {
                ($0.value.first ?? 0) * ($0.value.last ?? 0) <
                ($1.value.first ?? 0) * ($1.value.last ?? 0)
            }
            if let url = best?.key, isAbsoluteURL(url) { return url }
        }

        // 2. #landingImage src
        if let img = try? document.select("#landingImage").first(),
           let src = try? img.attr("src"),
           !src.isEmpty,
           isAbsoluteURL(src) {
            return src
        }

        // 3. #imgTagWrapperId img src
        if let img = try? document.select("#imgTagWrapperId img").first(),
           let src = try? img.attr("src"),
           !src.isEmpty,
           isAbsoluteURL(src) {
            return src
        }

        return nil
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
        let escaped = property.replacingOccurrences(of: "'", with: "\\'")
        let selector = "meta[property='\(escaped)'], meta[name='\(escaped)']"
        guard let element = try? document.select(selector).first() else {
            return nil
        }
        return try? element.attr("content")
    }

    private func isAbsoluteURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }
}
