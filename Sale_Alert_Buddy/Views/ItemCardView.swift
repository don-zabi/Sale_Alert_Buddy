import SwiftUI

/// A card summarising a tracked item: image, title, price state, and status.
struct ItemCardView: View {

    let item: TrackingItem

    @AppStorage("selectedLanguage") private var selectedLanguage = "en"

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            productImage

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                sourceRow

                priceSection

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(verbatim: relativeTime(item.lastCheckedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    // MARK: - Sub-views

    private var productImage: some View {
        AsyncImage(url: URL(string: item.imageUrl ?? "")) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure, .empty:
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .overlay {
                        Image(systemName: "cart")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
            @unknown default:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var sourceRow: some View {
        HStack(spacing: 4) {
            AsyncImage(url: item.faviconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                default:
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 13, height: 13)
                }
            }
            Text(verbatim: item.siteDisplayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var priceSection: some View {
        if let latest = formattedLatestPrice, let dropPct = formattedDropPercentage {
            // Price has dropped — hero price in green + drop badge
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: latest)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)

                HStack(spacing: 6) {
                    Text(verbatim: formattedBaselinePrice)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .strikethrough()

                    Text(verbatim: "↓ \(dropPct)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                }
            }
        } else if let latest = formattedLatestPrice, let risePct = formattedRisePercentage {
            // Price has risen — hero price in red + rise badge
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: latest)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.red)

                HStack(spacing: 6) {
                    Text(verbatim: formattedBaselinePrice)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .strikethrough()

                    Text(verbatim: "↑ \(risePct)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                }
            }
        } else if let latest = formattedLatestPrice {
            // Latest available, no change
            Text(verbatim: latest)
                .font(.subheadline)
                .fontWeight(.semibold)
        } else {
            // No check yet — baseline in muted style
            Text(verbatim: formattedBaselinePrice)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch item.itemStatus {
        case .ok:         return .green
        case .tempFailed: return .orange
        case .paused:     return Color(.systemGray3)
        }
    }

    private var formattedBaselinePrice: String {
        NotificationService.formatPrice(item.baselinePriceDecimal, currency: item.baselineCurrency)
    }

    private var formattedLatestPrice: String? {
        guard let latest = item.latestPriceDecimal,
              let currency = item.latestCurrency else { return nil }
        return NotificationService.formatPrice(latest, currency: currency)
    }

    private var formattedDropPercentage: String? {
        guard let pct = item.dropPercentage else { return nil }
        return String(format: "%.1f%%", pct)
    }

    private var formattedRisePercentage: String? {
        guard let pct = item.risePercentage else { return nil }
        return String(format: "%.1f%%", pct)
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else {
            return String(localized: "time.never", defaultValue: "Never",
                          locale: Locale(identifier: selectedLanguage))
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: selectedLanguage)
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
