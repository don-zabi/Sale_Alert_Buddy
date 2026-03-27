import Foundation

enum FetchErrorType: Int16 {
    case none = 0
    case network = 1
    case http4xx = 2
    case http5xx = 3
    case extractionFailed = 4

    var displayName: String {
        switch self {
        case .none: return ""
        case .network: return String(localized: "error.network", defaultValue: "Network error")
        case .http4xx: return String(localized: "error.http4xx", defaultValue: "Access blocked (4xx)")
        case .http5xx: return String(localized: "error.http5xx", defaultValue: "Server error (5xx)")
        case .extractionFailed: return String(localized: "error.extraction", defaultValue: "Price not found in page")
        }
    }
}
