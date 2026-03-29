import Foundation

enum ProtectionPageDetector {

    nonisolated static func isProtectionPage(_ html: String, url: URL) -> Bool {
        let normalized = html.lowercased()

        if normalized.contains("window._cf_chl_opt") ||
            normalized.contains("<title>just a moment...</title>") ||
            normalized.contains("enable javascript and cookies to continue") {
            return true
        }

        if normalized.contains("page_risk_crawler_block") ||
            normalized.contains("risk_challenge") ||
            normalized.contains("crawler_block") {
            return true
        }

        if normalized.contains("static.kwcdn.com/upload-static/assets/chl/js/") ||
            normalized.contains("/upload-static/assets/chl/js/") {
            return true
        }

        guard let host = url.host?.lowercased() else { return false }

        if host.contains("temu.com"),
           normalized.contains("kwcdn.com") &&
            normalized.contains("challenge") {
            return true
        }

        if host.contains("shein.com"),
           normalized.contains("page_name: 'page_risk_crawler_block'") {
            return true
        }

        return false
    }
}
