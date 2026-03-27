import SwiftUI

/// Displays a product's baseline price and, if it has dropped, the current price
/// with the drop amount and percentage.
///
/// - If `latest` is nil or equal to `baseline` (no drop data provided), shows
///   the baseline in gray.
/// - If a drop is present, shows baseline with strikethrough, an arrow, latest in
///   green, and a green drop badge.
struct PriceChangeView: View {

    /// Formatted baseline (original) price string.
    let baseline: String
    /// Formatted latest price string, or nil if no check has succeeded yet.
    let latest: String?
    /// Formatted drop amount (e.g. "-¥200"), or nil if no drop.
    let dropAmount: String?
    /// Formatted drop percentage (e.g. "10.2%"), or nil if no drop.
    let dropPercentage: String?

    var body: some View {
        if let latest, let dropAmount, let dropPercentage {
            // Price has dropped — show full detail
            HStack(alignment: .center, spacing: 6) {
                Text(verbatim: baseline)
                    .strikethrough(true, color: .secondary)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(verbatim: latest)
                    .foregroundStyle(.green)
                    .fontWeight(.semibold)
                    .font(.subheadline)

                Text(verbatim: "\(dropAmount) (\(dropPercentage))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
            }
        } else if let latest {
            // Latest price available but no drop
            HStack(spacing: 6) {
                Text(verbatim: baseline)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: latest)
                    .font(.subheadline)
            }
        } else {
            // No latest price yet — show baseline in gray
            Text(verbatim: baseline)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
    }
}

// MARK: - Preview

#Preview("No drop") {
    PriceChangeView(
        baseline: "¥1,980",
        latest: nil,
        dropAmount: nil,
        dropPercentage: nil
    )
    .padding()
}

#Preview("Price dropped") {
    PriceChangeView(
        baseline: "¥1,980",
        latest: "¥1,780",
        dropAmount: "-¥200",
        dropPercentage: "10.1%"
    )
    .padding()
}
