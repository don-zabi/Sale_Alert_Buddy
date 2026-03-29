import SwiftUI

enum NotificationConditionType: Int16, CaseIterable, Identifiable {
    case percentage = 0
    case amount = 1
    case targetPrice = 2

    var id: Int16 { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .percentage:
            return "notify.condition.percentage"
        case .amount:
            return "notify.condition.amount"
        case .targetPrice:
            return "notify.condition.targetPrice"
        }
    }

    /// Short label for compact segmented controls.
    var shortLabel: LocalizedStringKey {
        switch self {
        case .percentage:
            return "notify.condition.short.percentage"
        case .amount:
            return "notify.condition.short.amount"
        case .targetPrice:
            return "notify.condition.short.targetPrice"
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
