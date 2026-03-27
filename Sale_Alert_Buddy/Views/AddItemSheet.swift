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
                    String(localized: "addItem.memo.placeholder", defaultValue: "Optional note…"),
                    text: $viewModel.memo
                )
            } header: {
                Text(String(localized: "addItem.section.notes", defaultValue: "Notes (optional)"))
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
}

// MARK: - Preview

#Preview {
    AddItemSheet()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
