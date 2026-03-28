import Foundation

enum NotificationConditionType: Int16, CaseIterable, Identifiable {
    case percentage = 0
    case amount = 1
    case targetPrice = 2

    var id: Int16 { rawValue }

    var displayName: String {
        switch self {
        case .percentage:
            return String(localized: "notify.condition.percentage", defaultValue: "Percent Drop")
        case .amount:
            return String(localized: "notify.condition.amount", defaultValue: "Amount Drop")
        case .targetPrice:
            return String(localized: "notify.condition.targetPrice", defaultValue: "Price At Or Below")
        }
    }

    var defaultValue: Double {
        switch self {
        case .percentage:
            return 1
        case .amount:
            return 100
        case .targetPrice:
            return 0
        }
    }
}
