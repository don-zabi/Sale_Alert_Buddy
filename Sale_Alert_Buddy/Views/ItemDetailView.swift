import SwiftUI
import CoreData
import Charts

/// Detailed view for a single tracked item.
///
/// Shows product image, title, URL, prices, notification threshold,
/// status, action buttons, and a history of recent fetch logs.
struct ItemDetailView: View {

    @Environment(\.managedObjectContext) private var viewContext

    let item: TrackingItem

    @AppStorage("selectedLanguage") private var selectedLanguage = "en"
    @State private var viewModel: ItemDetailViewModel
    @State private var selectedNotificationType: NotificationConditionType
    @State private var notificationValueText: String

    init(item: TrackingItem) {
        self.item = item
        _viewModel = State(initialValue: ItemDetailViewModel(item: item))
        _selectedNotificationType = State(initialValue: item.itemNotificationConditionType)
        let value = item.itemNotificationConditionValue
        let valueText = value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
        _notificationValueText = State(initialValue: valueText)
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    priceSection
                    priceTrendSection
                    notificationSection
                    statusSection
                    actionsSection
                    recentChecksSection
                }
                .padding()
            }

            if viewModel.isChecking {
                loadingOverlay
            }
        }
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(localized: "detail.error.title", defaultValue: "Error"),
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "action.ok", defaultValue: "OK")) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Product image
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
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                @unknown default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Title
            Text(verbatim: item.displayTitle)
                .font(.title3)
                .fontWeight(.bold)

            // Tappable URL
            Button {
                viewModel.openInSafari()
            } label: {
                Text(verbatim: item.currentUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Price Section

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "detail.section.price", defaultValue: "Price"))
                .font(.headline)

            PriceChangeView(
                baseline: viewModel.formattedBaselinePrice,
                latest: viewModel.formattedLatestPrice,
                dropAmount: viewModel.formattedDropAmount,
                dropPercentage: viewModel.formattedDropPercentage
            )

            if let lastSuccess = item.lastSuccessAt {
                Text(verbatim: String(
                    format: String(localized: "detail.lastUpdated", defaultValue: "Last updated %@"),
                    relativeTime(lastSuccess)
                ))
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Notification Threshold

    private var priceTrendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "detail.section.priceTrend", defaultValue: "Price Trend"))
                .font(.headline)

            if viewModel.priceTrendPoints.count >= 2 {
                Chart(viewModel.priceTrendPoints) { point in
                    LineMark(
                        x: .value("Timestamp", point.timestamp),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(.tint)

                    PointMark(
                        x: .value("Timestamp", point.timestamp),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(.tint)
                    .symbolSize(20)
                }
                .frame(height: 180)
            } else {
                Text(String(
                    localized: "detail.priceTrend.empty",
                    defaultValue: "Price history will appear after two or more successful checks."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "detail.section.notification", defaultValue: "Notification"))
                .font(.headline)

            Text(verbatim: viewModel.notificationConditionDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker(
                String(localized: "detail.notifyThreshold.type", defaultValue: "Condition Type"),
                selection: $selectedNotificationType
            ) {
                ForEach(NotificationConditionType.allCases) { condition in
                    Text(condition.displayName).tag(condition)
                }
            }
            .pickerStyle(.menu)

            HStack {
                TextField(
                    String(localized: "detail.notifyThreshold.value", defaultValue: "Value"),
                    text: $notificationValueText
                )
                .keyboardType(.decimalPad)

                Text(notificationUnitLabel(for: selectedNotificationType))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(String(localized: "detail.notifyThreshold.save", defaultValue: "Save Notification Rule")) {
                viewModel.updateNotificationCondition(
                    type: selectedNotificationType,
                    valueText: notificationValueText,
                    context: viewContext
                )
                selectedNotificationType = viewModel.notificationConditionType
                notificationValueText = viewModel.notificationConditionValueText
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "detail.section.status", defaultValue: "Status"))
                .font(.headline)

            HStack(spacing: 8) {
                StatusBadge(status: item.itemStatus)
                Text(verbatim: viewModel.statusDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let reason = item.itemPauseReason, item.itemStatus == .paused {
                Text(verbatim: reason.displayMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 10) {
            // Check Now
            Button {
                Task {
                    await viewModel.checkNow(context: viewContext)
                }
            } label: {
                Label(
                    String(localized: "detail.action.checkNow", defaultValue: "Check Now"),
                    systemImage: "arrow.clockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isChecking)

            // Buy Now
            Button {
                viewModel.openInSafari()
            } label: {
                Label(
                    String(localized: "detail.action.buy", defaultValue: "Buy Now"),
                    systemImage: "cart.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            // Pause / Resume
            if item.itemStatus == .paused {
                Button {
                    viewModel.resume(context: viewContext)
                } label: {
                    Label(
                        String(localized: "detail.action.resume", defaultValue: "Resume Monitoring"),
                        systemImage: "play.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            } else {
                Button {
                    viewModel.pause(context: viewContext)
                } label: {
                    Label(
                        String(localized: "detail.action.pause", defaultValue: "Pause Monitoring"),
                        systemImage: "pause.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
    }

    // MARK: - Recent Checks Section

    private var recentChecksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "detail.section.recentChecks", defaultValue: "Recent Checks"))
                .font(.headline)

            let logs = Array(item.fetchLogsArray.prefix(10))

            if logs.isEmpty {
                Text(String(localized: "detail.noChecks", defaultValue: "No checks yet."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(logs) { log in
                        fetchLogRow(log)
                        if log.id != logs.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func fetchLogRow(_ log: FetchLog) -> some View {
        HStack(spacing: 10) {
            // Outcome icon
            Image(systemName: log.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(log.isSuccess ? .green : .red)
                .font(.callout)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: log.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                if !log.isSuccess {
                    Text(verbatim: log.fetchErrorType.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: log.fetchExtractMethod.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if log.httpStatus > 0 {
                    Text(verbatim: "HTTP \(log.httpStatus)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: "\(log.durationMs)ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            ProgressView()
                .scaleEffect(1.4)
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: selectedLanguage)
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func notificationUnitLabel(for type: NotificationConditionType) -> LocalizedStringKey {
        switch type {
        case .percentage:
            return "%"
        case .amount, .targetPrice:
            return "currency.jpy.unit"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ItemDetailView(item: {
            let ctx = PersistenceController.preview.container.viewContext
            let request = TrackingItem.fetchRequest()
            return (try? ctx.fetch(request))?.first ?? TrackingItem.create(in: ctx)
        }())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
