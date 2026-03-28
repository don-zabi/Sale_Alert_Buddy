import SwiftUI
import CoreData

/// Sheet for registering a new product URL to track.
struct AddItemSheet: View {

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = AddItemViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                form
                if viewModel.isRegistering {
                    loadingOverlay
                }
            }
            .navigationTitle(String(localized: "addItem.title", defaultValue: "Add Item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "action.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
            }
            .alert(
                String(localized: "addItem.error.title", defaultValue: "Registration Failed"),
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.clearError() } }
                )
            ) {
                Button(String(localized: "action.ok", defaultValue: "OK")) {
                    viewModel.clearError()
                }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onChange(of: viewModel.registeredItem) { _, newItem in
                if newItem != nil {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                TextField(
                    String(localized: "addItem.url.placeholder", defaultValue: "https://"),
                    text: $viewModel.urlText
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                if clipboardHasURL {
                    Button {
                        viewModel.pasteFromClipboard()
                    } label: {
                        Label(
                            String(localized: "addItem.pasteURL", defaultValue: "Paste from Clipboard"),
                            systemImage: "doc.on.clipboard"
                        )
                        .font(.subheadline)
                    }
                }
            } header: {
                Text(String(localized: "addItem.section.url", defaultValue: "Product URL"))
            }

            Section {
                TextField(
                    String(localized: "addItem.title.placeholder", defaultValue: "Optional custom title"),
                    text: $viewModel.titleText
                )
            } header: {
                Text(String(localized: "addItem.section.title", defaultValue: "Title (optional)"))
            } footer: {
                Text(String(
                    localized: "addItem.title.hint",
                    defaultValue: "If empty, the title is taken from the product page."
                ))
            }

            Section {
                TextField(
                    String(localized: "addItem.memo.placeholder", defaultValue: "Optional note…"),
                    text: $viewModel.memo
                )
            } header: {
                Text(String(localized: "addItem.section.notes", defaultValue: "Notes (optional)"))
            }

            Section {
                Picker(
                    String(localized: "addItem.notification.type", defaultValue: "Notify condition"),
                    selection: $viewModel.notificationConditionType
                ) {
                    ForEach(NotificationConditionType.allCases) { condition in
                        Text(condition.displayName).tag(condition)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.notificationConditionType) { _, newType in
                    viewModel.setDefaultConditionValue(for: newType)
                }

                HStack {
                    TextField(
                        String(localized: "addItem.notification.value.placeholder", defaultValue: "Value"),
                        text: $viewModel.notificationConditionValueText
                    )
                    .keyboardType(.decimalPad)

                    Text(notificationUnitLabel(for: viewModel.notificationConditionType))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "addItem.section.notification", defaultValue: "Notification Timing"))
            } footer: {
                Text(String(
                    localized: "addItem.notification.hint",
                    defaultValue: "Examples: 5 (%), 500 (JPY), or 10000 (notify when at or below)."
                ))
            }

            Section {
                TextField(
                    String(localized: "addItem.tags.placeholder", defaultValue: "tag1, tag2"),
                    text: $viewModel.tagsText
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
                Text(String(localized: "addItem.section.tags", defaultValue: "Tags (optional)"))
            } footer: {
                Text(String(localized: "addItem.tags.hint", defaultValue: "Separate tags with commas."))
            }

            Section {
                Button {
                    Task {
                        await viewModel.register(context: viewContext)
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text(String(localized: "addItem.register", defaultValue: "Register & Check"))
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!viewModel.canRegister)
            }
        }
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.4)
                Text(String(localized: "addItem.registering", defaultValue: "Checking price…"))
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Helpers

    private var clipboardHasURL: Bool {
        guard let string = UIPasteboard.general.string else { return false }
        return string.hasPrefix("http://") || string.hasPrefix("https://")
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
    AddItemSheet()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
