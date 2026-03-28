import SwiftUI

/// A list-row card showing a tracking item's summary: image, title, price change, and status.
struct ItemCardView: View {

    let item: TrackingItem

    @AppStorage("selectedLanguage") private var selectedLanguage = "en"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            productImage
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                priceRow
                bottomRow
            }
        }
        .padding(.vertical, 4)
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
                Image(systemName: "cart")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGray6))
            @unknown default:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var titleRow: some View {
        Text(verbatim: item.displayTitle)
            .font(.subheadline)
            .fontWeight(.semibold)
            .lineLimit(2)
    }

    private var priceRow: some View {
        PriceChangeView(
            baseline: NotificationService.formatPrice(
                item.baselinePriceDecimal,
                currency: item.baselineCurrency
            ),
            latest: formattedLatestPrice,
            dropAmount: formattedDropAmount,
            dropPercentage: formattedDropPercentage
        )
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            StatusBadge(status: item.itemStatus)
            Spacer()
            Text(verbatim: relativeTime(item.lastCheckedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var formattedLatestPrice: String? {
        guard let latest = item.latestPriceDecimal,
              let currency = item.latestCurrency else { return nil }
        return NotificationService.formatPrice(latest, currency: currency)
    }

    private var formattedDropAmount: String? {
        guard let drop = item.dropAmount else { return nil }
        let currency = item.latestCurrency ?? item.baselineCurrency
        return "-" + NotificationService.formatPrice(drop, currency: currency)
    }

    private var formattedDropPercentage: String? {
        guard let pct = item.dropPercentage else { return nil }
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
