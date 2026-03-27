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
        let filtered: [TrackingItem]
        switch viewModel.filterStatus {
        case .all:
            filtered = Array(items)
        case .activeOnly:
            filtered = items.filter { $0.itemStatus != .paused }
        case .pausedOnly:
            filtered = items.filter { $0.itemStatus == .paused }
        }

        switch viewModel.sortOrder {
        case .createdDesc:
            return filtered  // already sorted by Core Data fetch request
        case .priceDropDesc:
            return filtered.sorted { ($0.dropPercentage ?? 0) > ($1.dropPercentage ?? 0) }
        case .lastCheckedAsc:
            return filtered.sorted {
                ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ItemListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
