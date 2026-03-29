import SwiftUI

/// A horizontally scrollable filter bar with an "All" chip, category chips,
/// expand/collapse for overflow, and a compact add button.
struct CategoryBarView: View {

    /// All categories sorted by usage count (most-used first).
    let categories: [String]
    @Binding var selectedCategory: String?
    let onAdd: () -> Void
    let onEdit: (String) -> Void
    let onDelete: (String) -> Void

    private let maxVisible = 5
    @State private var isExpanded = false

    private var visibleCategories: [String] {
        isExpanded ? categories : Array(categories.prefix(maxVisible))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" — always first
                FilterChip(
                    label: String(localized: "list.category.all", defaultValue: "All"),
                    isSelected: selectedCategory == nil
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        selectedCategory = nil
                    }
                }

                ForEach(visibleCategories, id: \.self) { category in
                    CategoryChip(
                        label: category,
                        isSelected: selectedCategory == category,
                        onTap: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                selectedCategory = selectedCategory == category ? nil : category
                            }
                        },
                        onEdit: { onEdit(category) },
                        onDelete: { onDelete(category) }
                    )
                }

                if categories.count > maxVisible {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? "list.category.showLess" : "list.category.showMore")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Add category — compact circle icon
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - FilterChip (no context menu — for "All")

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Text(verbatim: label)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color(.systemGray5))
            )
            .contentShape(Capsule())
            .onTapGesture { onTap() }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }
}

// MARK: - CategoryChip (with context menu for edit/delete)

private struct CategoryChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Text(verbatim: label)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color(.systemGray5))
            )
            .contentShape(Capsule())
            .onTapGesture { onTap() }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
            .contextMenu {
                Button { onEdit() } label: {
                    Label("list.category.edit", systemImage: "pencil")
                }
                Button(role: .destructive) { onDelete() } label: {
                    Label("list.category.delete", systemImage: "trash")
                }
            }
    }
}

// MARK: - Previews

#Preview("With categories") {
    @Previewable @State var selected: String? = "Electronics"
    CategoryBarView(
        categories: ["Electronics", "Books", "Clothing", "Food", "Sports", "Music"],
        selectedCategory: $selected,
        onAdd: {},
        onEdit: { _ in },
        onDelete: { _ in }
    )
    .background(Color(.systemBackground))
}

#Preview("Empty") {
    @Previewable @State var selected: String? = nil
    CategoryBarView(
        categories: [],
        selectedCategory: $selected,
        onAdd: {},
        onEdit: { _ in },
        onDelete: { _ in }
    )
}
