import Foundation

/// The set of shops this build supports for accurate price detection.
///
/// Registration is currently restricted to these hosts. Everything else is
/// rejected with `PriceCheckError.unsupportedSite` so the app only tracks
/// prices it can extract deterministically.
enum SupportedShop: String, Sendable, CaseIterable {
    case amazon
    case mercari

    /// Resolves the supported shop for a URL, or `nil` for unsupported hosts.
    static func from(url: URL) -> SupportedShop? {
        from(host: url.host)
    }

    /// Resolves the supported shop for a raw host string, or `nil`.
    static func from(host: String?) -> SupportedShop? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        if isAmazonHost(host) { return .amazon }
        if isMercariHost(host) { return .mercari }
        return nil
    }

    /// Convenience: whether a URL points at any supported shop.
    static func isSupported(url: URL) -> Bool {
        from(url: url) != nil
    }

    var displayName: String {
        switch self {
        case .amazon: return "Amazon"
        case .mercari: return "Mercari"
        }
    }

    // MARK: - Host Matching

    /// Matches `amazon.<tld>`, `www.amazon.<tld>`, `*.amazon.<tld>`, and the
    /// known Amazon short-link domains (which redirect to a full product URL).
    static func isAmazonHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "amazon.co.jp" || h == "amazon.com" { return true }
        if h.hasPrefix("www.amazon.") || h.hasPrefix("amazon.") || h.contains(".amazon.") {
            return true
        }
        // Short-link domains.
        let shortDomains: Set<String> = ["amzn.to", "amzn.asia", "a.co", "amzn.eu", "amzn.com"]
        return shortDomains.contains(h)
    }

    /// Matches `mercari.com`, `jp.mercari.com`, and other `*.mercari.com` hosts.
    static func isMercariHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "mercari.com" || h.hasSuffix(".mercari.com")
    }

    // MARK: - Currency

    /// Best-effort ISO 4217 currency for a resolved host of this shop.
    ///
    /// Amazon marketplaces are currency-per-TLD; Mercari is JP-only for pricing
    /// purposes in this build. Defaults to JPY (the primary market) when a TLD
    /// is unknown or a short-link host hasn't been resolved yet.
    func currency(forHost host: String?) -> String {
        switch self {
        case .mercari:
            return "JPY"
        case .amazon:
            return Self.amazonCurrency(forHost: host)
        }
    }

    private static func amazonCurrency(forHost host: String?) -> String {
        guard let host = host?.lowercased() else { return "JPY" }
        // Ordered longest-suffix-first so "co.jp"/"co.uk" win over "com".
        let suffixCurrencies: [(String, String)] = [
            ("amazon.co.jp", "JPY"),
            ("amazon.co.uk", "GBP"),
            ("amazon.com.au", "AUD"),
            ("amazon.de", "EUR"),
            ("amazon.fr", "EUR"),
            ("amazon.it", "EUR"),
            ("amazon.es", "EUR"),
            ("amazon.nl", "EUR"),
            ("amazon.ca", "CAD"),
            ("amazon.com", "USD")
        ]
        for (suffix, currency) in suffixCurrencies where host == suffix || host.hasSuffix("." + suffix) {
            return currency
        }
        return "JPY"
    }
}
