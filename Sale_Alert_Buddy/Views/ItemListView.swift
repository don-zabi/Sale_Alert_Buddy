import SwiftUI
import CoreData

/// The main screen showing all tracked items.
///
/// Supports pull-to-refresh, sort/filter, swipe actions, and navigation to detail.
struct ItemListView: View {

    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        fetchRequest: TrackingItem.allItemsFetchRequest(),
        animation: .default
    ) private var items: FetchedResults<TrackingItem>

    @State private var viewModel = ItemListViewModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                itemList
                    .navigationTitle(String(localized: "app.title", defaultValue: "Sale Alert Buddy"))
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            settingsButton
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            categoryFilterMenu
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

                if viewModel.isChecking {
                    ProgressView(value: viewModel.checkProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(maxWidth: .infinity)
                }
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

    // MARK: - Sub-views

    @ViewBuilder
    private var itemList: some View {
        if filteredItems.isEmpty && !viewModel.isChecking {
            emptyStateView
        } else {
            List {
                ForEach(filteredItems) { item in
                    NavigationLink(destination: ItemDetailView(item: item)) {
                        ItemCardView(item: item)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel.deleteItem(item, context: viewContext)
                        } label: {
                            Label(
                                String(localized: "action.delete", defaultValue: "Delete"),
                                systemImage: "trash"
                            )
                        }
                    }
                    .swipeActions(edge: .leading) {
                        pauseResumeAction(for: item)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            String(localized: "list.empty.title", defaultValue: "No items yet"),
            systemImage: "cart.badge.plus",
            description: Text(
                String(localized: "list.empty.description", defaultValue: "Tap + to add a product URL.")
            )
        )
    }

    private var settingsButton: some View {
        NavigationLink(destination: SettingsView()) {
            Image(systemName: "gearshape")
                .accessibilityLabel(String(localized: "settings.title", defaultValue: "Settings"))
        }
    }

    private var addButton: some View {
        Button {
            viewModel.showingAddSheet = true
        } label: {
            Image(systemName: "plus")
                .accessibilityLabel(String(localized: "action.addItem", defaultValue: "Add Item"))
        }
    }

    private var categoryFilterMenu: some View {
        Menu {
            Button {
                viewModel.selectedCategory = nil
            } label: {
                Label(
                    String(localized: "list.category.all", defaultValue: "All Categories"),
                    systemImage: viewModel.selectedCategory == nil ? "checkmark" : "line.3.horizontal.decrease.circle"
                )
            }

            if !availableCategories.isEmpty {
                Divider()
                ForEach(availableCategories, id: \.self) { category in
                    Button {
                        viewModel.selectedCategory = category
                    } label: {
                        Label(
                            title: { Text(verbatim: category) },
                            icon: {
                                if viewModel.selectedCategory == category {
                                    Image(systemName: "checkmark")
                                }
                            }
                        )
                    }
                }
            }
        } label: {
            Image(systemName: viewModel.selectedCategory == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .accessibilityLabel(String(localized: "list.category.filter", defaultValue: "Filter by Category"))
        }
    }

    @ViewBuilder
    private func pauseResumeAction(for item: TrackingItem) -> some View {
        if item.itemStatus == .paused {
            Button {
                viewModel.resumeItem(item, context: viewContext)
            } label: {
                Label(
                    String(localized: "action.resume", defaultValue: "Resume"),
                    systemImage: "play.circle"
                )
            }
            .tint(.green)
        } else {
            Button {
                viewModel.pauseItem(item, context: viewContext)
            } label: {
                Label(
                    String(localized: "action.pause", defaultValue: "Pause"),
                    systemImage: "pause.circle"
                )
            }
            .tint(.orange)
        }
    }

    // MARK: - Filtering

    /// Applies the active `filterStatus` and `sortOrder` to the fetched results.
    ///
    /// Note: Core Data `@FetchRequest` owns the primary sort (createdAt desc).
    /// Secondary sorts applied here are in-memory and remain reactive via SwiftUI.
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
            return categoryFiltered  // already sorted by Core Data fetch request
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
