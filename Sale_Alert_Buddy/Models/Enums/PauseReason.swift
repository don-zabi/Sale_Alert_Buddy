import Foundation

enum PauseReason: Int16 {
    case userInitiated = 1
    case planLimit = 2
    case consecutiveFailures = 3

    var displayMessage: String {
        switch self {
        case .userInitiated: return String(localized: "pauseReason.user", defaultValue: "Manually paused")
        case .planLimit: return String(localized: "pauseReason.planLimit", defaultValue: "Paused: free plan limit (upgrade to add more)")
        case .consecutiveFailures: return String(localized: "pauseReason.failures", defaultValue: "Paused after repeated fetch failures")
        }
    }
}
