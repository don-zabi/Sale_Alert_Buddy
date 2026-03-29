import SwiftUI
import CoreData

/// The main screen showing all tracked items.
///
/// Card-style list with category filter bar, pull-to-refresh,
/// swipe actions, and navigation to detail.
struct ItemListView: View {

    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        fetchRequest: TrackingItem.allItemsFetchRequest(),
        animation: .default
    ) private var items: FetchedResults<TrackingItem>

    @State private var viewModel = ItemListViewModel()
    @State private var manualCaptureTarget: TrackingItem?
    @State private var manualCaptureSuccessMessage: String?

    var body: some View {
        NavigationStack {
            itemList
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        settingsButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        addButton
                    }
                }
                .refreshable {
                    await viewModel.checkAll(context: viewContext)
                }
                .sheet(isPresented: $viewModel.showingAddSheet) {
                    AddItemSheet()
                        .environment(\.managedObjectContext, viewContext)
                }
                .sheet(item: $manualCaptureTarget) { item in
                    if let itemURL = URL(string: item.currentUrl) {
                        InAppPriceCaptureSheet(
                            initialURL: itemURL,
                            title: String(
                                localized: "manualCapture.list.title",
                                defaultValue: "手動で価格確認"
                            )
                        ) { html, pageURL in
                            let response = await viewModel.handleManualCapture(
                                for: item,
                                html: html,
                                pageURL: pageURL,
                                context: viewContext
                            )
                            if response.shouldDismiss {
                                manualCaptureSuccessMessage = response.message
                            }
                            return response
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if viewModel.isChecking {
                            ProgressView(value: viewModel.checkProgress)
                                .progressViewStyle(.linear)
                                .tint(.accentColor)
                        }
                        CategoryBarView(
                            categories: viewModel.sortedCategories(from: Array(items)),
                            selectedCategory: $viewModel.selectedCategory,
                            onAdd: { viewModel.startAddingCategory() },
                            onEdit: { viewModel.startEditingCategory($0) },
                            onDelete: { viewModel.startDeletingCategory($0) }
                        )
                        Divider()
                    }
                    .background(.bar)
                }
                .alert("list.category.add.title", isPresented: $viewModel.showingCategoryAdd) {
                    TextField("list.category.name.placeholder", text: $viewModel.categoryNameInput)
                    Button("action.cancel", role: .cancel) { viewModel.cancelCategoryAction() }
                    Button("list.category.add") { viewModel.confirmAddCategory() }
                }
                .alert("list.category.edit.title", isPresented: $viewModel.showingCategoryEdit) {
                    TextField("list.category.name.placeholder", text: $viewModel.categoryNameInput)
                    Button("action.cancel", role: .cancel) { viewModel.cancelCategoryAction() }
                    Button("list.category.edit") {
                        viewModel.confirmRenameCategory(items: Array(items), context: viewContext)
                    }
                }
                .alert("list.category.delete.title", isPresented: $viewModel.showingCategoryDeleteConfirm) {
                    Button("action.cancel", role: .cancel) {
                        viewModel.categoryDeleteTarget = nil
                        viewModel.showingCategoryDeleteConfirm = false
                    }
                    Button("list.category.delete", role: .destructive) {
                        viewModel.confirmDeleteCategory(items: Array(items), context: viewContext)
                    }
                } message: {
                    Text("list.category.delete.confirm")
                }
                .alert(
                    String(
                        localized: "manualCapture.success.title",
                        defaultValue: "価格を更新しました"
                    ),
                    isPresented: Binding(
                        get: { manualCaptureSuccessMessage != nil },
                        set: { if !$0 { manualCaptureSuccessMessage = nil } }
                    )
                ) {
                    Button("action.ok", role: .cancel) {
                        manualCaptureSuccessMessage = nil
                    }
                } message: {
                    Text(manualCaptureSuccessMessage ?? "")
                }
        }
        .task {
            _ = await NotificationService.shared.requestPermission()
        }
        .onChange(of: availableCategories) { _, categories in
            if let selected = viewModel.selectedCategory, !categories.contains(selected) {
                viewModel.selectedCategory = nil
            }
        }
    }

    // MARK: - Item List

    @ViewBuilder
    private var itemList: some View {
        if filteredItems.isEmpty && !viewModel.isChecking {
            emptyStateView
        } else {
            List {
                ForEach(filteredItems) { item in
                    VStack(alignment: .trailing, spacing: 8) {
                        ZStack {
                            // Invisible NavigationLink hides the disclosure chevron
                            NavigationLink(destination: ItemDetailView(item: item)) {
                                EmptyView()
                            }
                            .opacity(0)

                            ItemCardView(item: item)
                        }

                        if viewModel.shouldOfferManualCheck(for: item) {
                            Button {
                                manualCaptureTarget = item
                            } label: {
                                Label(
                                    String(
                                        localized: "manualCapture.list.button",
                                        defaultValue: "手動で確認"
                                    ),
                                    systemImage: "hand.tap"
                                )
                                .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel.deleteItem(item, context: viewContext)
                        } label: {
                            Label("action.delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        pauseResumeAction(for: item)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ContentUnavailableView(
            "list.empty.title",
            systemImage: "cart.badge.plus",
            description: Text("list.empty.description")
        )
    }

    // MARK: - Toolbar

    private var settingsButton: some View {
        NavigationLink(destination: SettingsView()) {
            Image(systemName: "gearshape")
                .accessibilityLabel(Text("settings.title"))
        }
    }

    private var addButton: some View {
        Button {
            viewModel.showingAddSheet = true
        } label: {
            Image(systemName: "plus")
                .fontWeight(.semibold)
                .accessibilityLabel(Text("action.addItem"))
        }
    }

    // MARK: - Swipe Actions

    @ViewBuilder
    private func pauseResumeAction(for item: TrackingItem) -> some View {
        if item.itemStatus == .paused {
            Button {
                viewModel.resumeItem(item, context: viewContext)
            } label: {
                Label("action.resume", systemImage: "play.circle")
            }
            .tint(.green)
        } else {
            Button {
                viewModel.pauseItem(item, context: viewContext)
            } label: {
                Label("action.pause", systemImage: "pause.circle")
            }
            .tint(.orange)
        }
    }

    // MARK: - Filtering

    private var filteredItems: [TrackingItem] {
        let statusFiltered: [TrackingItem]
        switch viewModel.filterStatus {
        case .all:
            statusFiltered = Array(items)
        case .activeOnly:
            statusFiltered = items.filter { $0.itemStatus != .paused }
        case .pausedOnly:
            statusFiltered = items.filter { $0.itemStatus == .paused }
        }

        let categoryFiltered: [TrackingItem]
        if let selectedCategory = viewModel.selectedCategory {
            categoryFiltered = statusFiltered.filter { $0.itemCategory == selectedCategory }
        } else {
            categoryFiltered = statusFiltered
        }

        switch viewModel.sortOrder {
        case .createdDesc:
            return categoryFiltered
        case .priceDropDesc:
            return categoryFiltered.sorted { ($0.dropPercentage ?? 0) > ($1.dropPercentage ?? 0) }
        case .lastCheckedAsc:
            return categoryFiltered.sorted {
                ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast)
            }
        }
    }

    private var availableCategories: [String] {
        let categories = items.compactMap(\.itemCategory)
        return Array(Set(categories)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - Preview

#Preview {
    ItemListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
