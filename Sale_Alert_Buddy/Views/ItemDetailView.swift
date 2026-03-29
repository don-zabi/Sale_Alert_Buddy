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
    @FocusState private var isValueFieldFocused: Bool
    @State private var showSavedFeedback = false
    @State private var showingDeleteConfirm = false

    @FetchRequest(
        fetchRequest: TrackingItem.allItemsFetchRequest(),
        animation: .none
    ) private var allItems: FetchedResults<TrackingItem>

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
                    categorySection
                    memoSection
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
        .alert("list.category.edit.title", isPresented: $viewModel.showingCategoryEdit) {
            TextField("list.category.name.placeholder", text: $viewModel.categoryNameInput)
            Button("action.cancel", role: .cancel) {
                viewModel.showingCategoryEdit = false
                viewModel.categoryNameInput = ""
            }
            Button("action.save") {
                viewModel.saveCategoryEdit(context: viewContext)
            }
        }
        .alert(
            String(localized: "detail.memo.edit.title", defaultValue: "Edit Note"),
            isPresented: $viewModel.showingMemoEdit
        ) {
            TextField("addItem.memo.placeholder", text: $viewModel.memoInput)
            Button("action.cancel", role: .cancel) {
                viewModel.showingMemoEdit = false
                viewModel.memoInput = ""
            }
            Button("action.save") {
                viewModel.saveMemoEdit(context: viewContext)
            }
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

    // MARK: - Category Section

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("detail.section.category")
                .font(.headline)

            if let category = item.itemCategory {
                HStack(spacing: 10) {
                    Text(verbatim: category)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())

                    Spacer()

                    Button {
                        viewModel.startEditingCategory()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        viewModel.clearCategory(context: viewContext)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("detail.category.none")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if item.itemCategory == nil {
                    Button {
                        viewModel.startEditingCategory()
                    } label: {
                        Label("list.category.add", systemImage: "plus")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }

                if !otherCategories.isEmpty {
                    Menu {
                        ForEach(otherCategories, id: \.self) { cat in
                            Button {
                                viewModel.setCategory(cat, context: viewContext)
                            } label: {
                                Text(verbatim: cat)
                            }
                        }
                    } label: {
                        Label("addItem.category.pickExisting", systemImage: "folder")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Categories used by other items (excludes the current item's category).
    private var otherCategories: [String] {
        let all = allItems.compactMap(\.itemCategory)
        let unique = Array(Set(all)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return unique.filter { $0 != item.itemCategory }
    }

    private var memoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("addItem.section.notes")
                    .font(.headline)

                Spacer()

                if memoText != nil {
                    Button {
                        viewModel.startEditingMemo()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        viewModel.clearMemo(context: viewContext)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let memoText {
                Text(verbatim: memoText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "detail.memo.empty", defaultValue: "No note yet."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.startEditingMemo()
                } label: {
                    Label {
                        Text(String(localized: "detail.memo.add", defaultValue: "Add Note"))
                    } icon: {
                        Image(systemName: "plus")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
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
                .chartYScale(domain: viewModel.chartYDomain)
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
        VStack(alignment: .leading, spacing: 14) {

            // Header + current saved rule
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "detail.section.notification", defaultValue: "Notification"))
                    .font(.headline)

                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "detail.notify.currentSetting", defaultValue: "Current setting:"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(verbatim: viewModel.notificationConditionDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let targetPrice = viewModel.savedNotificationTargetPrice {
                            Text(verbatim: String(
                                format: String(
                                    localized: "detail.notify.targetCalc",
                                    defaultValue: "→ Notify at %@ or below"
                                ),
                                targetPrice
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Condition type + value input — single row
            HStack(spacing: 10) {
                // Custom segmented control
                HStack(spacing: 2) {
                    ForEach(NotificationConditionType.allCases) { condition in
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                selectedNotificationType = condition
                            }
                        } label: {
                            Text(condition.shortLabel)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .foregroundStyle(
                                    selectedNotificationType == condition ? .white : .secondary
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(
                                    selectedNotificationType == condition
                                        ? Color.accentColor
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: selectedNotificationType)
                    }
                }
                .padding(3)
                .background(Color(.systemGray4).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                // Value input with unit label
                HStack(spacing: 4) {
                    TextField(
                        "0",
                        text: $notificationValueText
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 48)
                    .focused($isValueFieldFocused)
                    .onChange(of: isValueFieldFocused) { _, focused in
                        guard focused else { return }
                        // Move cursor to end so the user can immediately edit
                        DispatchQueue.main.async {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.selectAll(_:)),
                                to: nil, from: nil, for: nil
                            )
                        }
                    }

                    Text(notificationUnitLabel(for: selectedNotificationType))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isValueFieldFocused ? Color.accentColor : Color(.systemGray4), lineWidth: isValueFieldFocused ? 1.5 : 1)
                )
            }

            // Real-time preview of the rule being edited
            if let preview = viewModel.editingPreview(
                type: selectedNotificationType,
                valueText: notificationValueText
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: preview.description)
                        .font(.caption)
                        .foregroundStyle(.primary)

                    if let targetPrice = preview.targetPrice {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text(verbatim: String(
                                format: String(
                                    localized: "detail.notify.targetCalc",
                                    defaultValue: "Notify at %@ or below"
                                ),
                                targetPrice
                            ))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .animation(.easeInOut(duration: 0.15), value: notificationValueText)
                .animation(.easeInOut(duration: 0.15), value: selectedNotificationType)
            }

            Button(String(localized: "detail.notifyThreshold.save", defaultValue: "Save Notification Rule")) {
                viewModel.updateNotificationCondition(
                    type: selectedNotificationType,
                    valueText: notificationValueText,
                    context: viewContext
                )
                selectedNotificationType = viewModel.notificationConditionType
                notificationValueText = viewModel.notificationConditionValueText
                isValueFieldFocused = false
                withAnimation(.easeInOut(duration: 0.2)) { showSavedFeedback = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeOut(duration: 0.3)) { showSavedFeedback = false }
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

            if showSavedFeedback {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(String(localized: "detail.notifyThreshold.saved", defaultValue: "Changes saved"))
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.green)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
            }
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

            // Delete
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label(
                    String(localized: "action.delete", defaultValue: "Delete"),
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .confirmationDialog(
                String(localized: "detail.action.delete.confirm",
                       defaultValue: "Delete this item?"),
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(
                    String(localized: "action.delete", defaultValue: "Delete"),
                    role: .destructive
                ) {
                    viewModel.deleteItem(context: viewContext)
                }
            } message: {
                Text(String(localized: "detail.action.delete.message",
                            defaultValue: "This item and all its price history will be permanently removed."))
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

    private var memoText: String? {
        guard let memo = item.memo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !memo.isEmpty else {
            return nil
        }
        return memo
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
