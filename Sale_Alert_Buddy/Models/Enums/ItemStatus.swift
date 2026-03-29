import SwiftUI

enum ItemStatus: Int16, CaseIterable {
    case ok = 0
    case tempFailed = 1
    case paused = 2

    var displayName: String {
        switch self {
        case .ok: return String(localized: "status.ok", defaultValue: "Active")
        case .tempFailed: return String(localized: "status.tempFailed", defaultValue: "Check Failed")
        case .paused: return String(localized: "status.paused", defaultValue: "Paused")
        }
    }

    var displayKey: LocalizedStringKey {
        switch self {
        case .ok: return "status.ok"
        case .tempFailed: return "status.tempFailed"
        case .paused: return "status.paused"
        }
    }

    var isActive: Bool { self != .paused }
}
