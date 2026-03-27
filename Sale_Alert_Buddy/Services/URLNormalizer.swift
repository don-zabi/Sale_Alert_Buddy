import Foundation

struct URLNormalizer {

    /// Tracking query parameter names that should be stripped from URLs.
    private static let trackingParams: Set<String> = [
        "fbclid",
        "ref",
        "ref_",
        "gclid",
        "msclkid",
        "sc_i",
        "scid",
        "dib",
        "dib_tag",
        "source_location"
    ]

    /// Returns a normalized, tracking-free version of the URL string,
    /// or nil if the input is not a valid absolute HTTP(S) URL or targets a
    /// private/loopback address (SSRF prevention).
    static func normalize(_ urlString: String) -> String? {
        // Reject excessively long input before any parsing
        guard urlString.count <= 2048 else { return nil }

        guard var components = URLComponents(string: urlString) else { return nil }

        // Only accept http and https
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        // Must have a non-empty host
        guard let host = components.host, !host.isEmpty else { return nil }

        // Block loopback, private, and link-local addresses to prevent SSRF.
        // Hostname-based checks are performed here; DNS-rebinding is a theoretical
        // bypass (the device can't be fully protected without connection-time IP
        // validation), but this eliminates casual misuse.
        guard !isPrivateHost(host.lowercased()) else { return nil }

        // Lowercase scheme and host
        components.scheme = scheme
        components.host = host.lowercased()

        // Remove trailing slash from path (but keep "/" root as empty path)
        var path = components.path
        if path != "/" && path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        // Convert bare "/" to "" so the URL renders without trailing slash
        if path == "/" {
            path = ""
        }
        components.path = path

        // Filter and sort query parameters
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let filtered = queryItems.filter { item in
                let name = item.name
                // Remove any param starting with "utm_"
                if name.hasPrefix("utm_") { return false }
                // Remove known tracking params
                if trackingParams.contains(name) { return false }
                return true
            }
            // Sort alphabetically for stable comparison
            let sorted = filtered.sorted { $0.name < $1.name }
            components.queryItems = sorted.isEmpty ? nil : sorted
        }

        return components.url?.absoluteString
    }

    // MARK: - Private Network Detection

    /// Returns true if `host` refers to localhost, loopback, or a private/link-local range.
    ///
    /// Covers:
    /// - Loopback:      `localhost`, `127.x.x.x`, `::1`, `0.0.0.0`
    /// - Private IPv4:  `10.x.x.x`, `172.16–31.x.x`, `192.168.x.x`
    /// - Link-local:    `169.254.x.x`, `fe80::/10`
    /// - Multicast:     `224.x.x.x – 239.x.x.x`
    private static func isPrivateHost(_ host: String) -> Bool {
        // Loopback / special hostnames
        if host == "localhost" || host == "0.0.0.0" || host == "::1" { return true }

        // Bracket-stripped IPv6
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "::1" || bare.lowercased().hasPrefix("fe80") { return true }

        // Parse as IPv4
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let a = Int(parts[0]),
              let b = Int(parts[1]) else { return false }

        switch a {
        case 10:         return true          // 10.0.0.0/8
        case 127:        return true          // 127.0.0.0/8 (loopback)
        case 169:        return b == 254      // 169.254.0.0/16 (link-local)
        case 172:        return b >= 16 && b <= 31  // 172.16.0.0/12
        case 192:        return b == 168     // 192.168.0.0/16
        case 224...239:  return true          // 224.0.0.0/4 (multicast)
        default:         return false
        }
    }
}
