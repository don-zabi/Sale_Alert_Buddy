import SwiftUI

/// A small capsule badge showing an item's monitoring status.
///
/// Colors:
/// - `.ok`         → green, "Active" / "監視中"
/// - `.tempFailed` → orange, "Check Failed" / "取得失敗"
/// - `.paused`     → gray, "Paused" / "停止中"
struct StatusBadge: View {

    let status: ItemStatus

    var body: some View {
        Text(status.displayKey)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor, in: Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .ok:         return .green
        case .tempFailed: return .orange
        case .paused:     return .secondary
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        StatusBadge(status: .ok)
        StatusBadge(status: .tempFailed)
        StatusBadge(status: .paused)
    }
    .padding()
}
