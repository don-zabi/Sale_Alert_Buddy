import SwiftUI
import CoreData

/// Sheet for registering a new product URL to track.
struct AddItemSheet: View {

    private struct ManualCaptureTarget: Identifiable {
        let id = UUID()
        let url: URL
    }

    private enum Field: Hashable {
        case url
        case title
        case category
        case memo
        case notificationValue
    }

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FetchRequest(
        fetchRequest: TrackingItem.allItemsFetchRequest(),
        animation: .default
    ) private var existingItems: FetchedResults<TrackingItem>

    @State private var viewModel = AddItemViewModel()
    @State private var clipboardHasURL: Bool = false
    @State private var webViewLoading: Bool = false
    @State private var manualCaptureTarget: ManualCaptureTarget?
    @FocusState private var focusedField: Field?

    var body: some View {
        // ZStack lets the custom review card overlay the NavigationStack cleanly.
        ZStack(alignment: .bottom) {
            NavigationStack {
                presentedContent(baseContent)
            }

            // Dimmer + review card — animated as a unit
            if viewModel.reviewDialog != nil {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { viewModel.reviewDialog = nil }
                    .transition(.opacity)
                    .zIndex(10)
            }

            if let dialog = viewModel.reviewDialog {
                reviewCard(dialog)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(11)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.reviewDialog != nil)
    }

    // MARK: - Base Content

    private var baseContent: some View {
        ZStack(alignment: .bottom) {
            form
                .padding(.bottom, bottomFloatingInset)

            if showFloatingRegisterButton {
                if viewModel.priceConfirmed {
                    confirmRegistrationButton
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    registerButtonOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if viewModel.isRegistering {
                loadingOverlay
            }
        }
        .navigationTitle("addItem.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("action.cancel") {
                    dismiss()
                }
            }
        }
    }

    private func presentedContent<Content: View>(_ content: Content) -> some View {
        content
            .alert(
                "addItem.error.title",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.clearError() } }
                )
            ) {
                Button("action.ok") { viewModel.clearError() }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert(
                "addItem.error.title",
                isPresented: Binding(
                    get: { viewModel.securityBlockMessage != nil },
                    set: { if !$0 { viewModel.securityBlockMessage = nil } }
                )
            ) {
                Button("action.ok") {
                    viewModel.securityBlockMessage = nil
                    dismiss()
                }
            } message: {
                Text(viewModel.securityBlockMessage ?? "")
            }
            .onChange(of: viewModel.registeredItem) { _, newItem in
                if newItem != nil { dismiss() }
            }
            .onChange(of: viewModel.reviewDialog) { _, newDialog in
                if newDialog == nil {
                    webViewLoading = false
                    viewModel.clearPreviewState()
                }
            }
            .onAppear { refreshClipboardAvailability() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { refreshClipboardAvailability() }
            }
            .sheet(item: $manualCaptureTarget) { target in
                InAppPriceCaptureSheet(
                    initialURL: target.url,
                    title: String(
                        localized: "manualCapture.list.title",
                        defaultValue: "手動で価格確認"
                    )
                ) { capturedPage in
                    await viewModel.handleManualCapture(
                        capturedPage: capturedPage,
                        context: viewContext
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showFloatingRegisterButton)
    }

    // MARK: - Review Card (replaces confirmationDialog)

    /// Custom bottom card that shows a rich product preview alongside action buttons.
    /// Takes up ~82% of screen height so the inline web preview is easy to read.
    @ViewBuilder
    private func reviewCard(_ dialog: AddItemViewModel.RegistrationReviewDialog) -> some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 10)

            // Title
            Text(verbatim: dialog.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Product preview card (detected dialogs only)
            if dialog.kind == .detected {
                productPreview(dialog)
                    .padding(.top, 10)
                    .padding(.horizontal)

                // Price area preview — fills remaining card space.
                // 1st attempt: prefer a sanitized screenshot, but fall back quickly to the
                // live sanitized preview if capture is slow or blank. Retry/manual flows
                // show the live sanitized preview immediately.
                previewSurface(dialog)
                .padding(.top, 8)
                .padding(.horizontal)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            } else {
                // Failure message
                Text(verbatim: dialog.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            // Action buttons
            reviewButtons(dialog)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.82)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Compact thumbnail + title + detected price row.
    @ViewBuilder
    private func productPreview(_ dialog: AddItemViewModel.RegistrationReviewDialog) -> some View {
        HStack(spacing: 10) {
            // Thumbnail
            Group {
                if let urlString = dialog.previewImageURL,
                   let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            placeholderThumbnail
                        }
                    }
                } else {
                    placeholderThumbnail
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                if let title = dialog.previewTitle, !title.isEmpty {
                    Text(verbatim: title)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                if let price = dialog.previewPrice {
                    Text(verbatim: price)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                }
            }

            Spacer(minLength: 0)

            // "Detected" badge
            Text(String(localized: "addItem.review.detected.badge", defaultValue: "検出"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule())
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    /// Inline WKWebView showing the actual product page with the price element highlighted.
    /// Purchase buttons and sticky CTAs are hidden before render; navigation stays read-only.
    @ViewBuilder
    private func webPreview(url: URL, priceDecimal: Decimal?) -> some View {
        ZStack(alignment: .topTrailing) {
            PricePreviewWebView(url: url, priceDecimal: priceDecimal, isLoading: $webViewLoading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Read-only badge — reassures the user that tapping site buttons does nothing
            Text(String(localized: "addItem.review.webPreview.readOnly",
                        defaultValue: "プレビューのみ"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(8)

            if webViewLoading {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(String(localized: "addItem.review.webPreview.loading",
                                        defaultValue: "サイトを読み込み中…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    )
            }
        }
    }

    @ViewBuilder
    private func previewSurface(_ dialog: AddItemViewModel.RegistrationReviewDialog) -> some View {
        if dialog.prefersScreenshot {
            ZStack {
                if let previewURL = dialog.previewURL {
                    webPreview(url: previewURL, priceDecimal: dialog.previewPriceDecimal)
                        .allowsHitTesting(viewModel.previewPresentationMode == .liveWeb)
                        .accessibilityHidden(viewModel.previewPresentationMode != .liveWeb)
                }

                switch viewModel.previewPresentationMode {
                case .screenshot:
                    if let screenshot = viewModel.previewScreenshot {
                        screenshotPreview(screenshot)
                    } else {
                        screenshotLoadingPlaceholder
                    }
                case .idle, .loadingScreenshot:
                    screenshotLoadingPlaceholder
                case .liveWeb:
                    EmptyView()
                }
            }
        } else if let previewURL = dialog.previewURL {
            webPreview(url: previewURL, priceDecimal: dialog.previewPriceDecimal)
        } else if let screenshot = viewModel.previewScreenshot {
            screenshotPreview(screenshot)
        } else {
            screenshotLoadingPlaceholder
        }
    }

    /// Shows a captured screenshot with a subtle "プレビュー" badge.
    @ViewBuilder
    private func screenshotPreview(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Text(String(localized: "addItem.review.webPreview.readOnly",
                            defaultValue: "プレビューのみ"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
    }

    /// Placeholder shown while the off-screen screenshot is being captured.
    private var screenshotLoadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                VStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "addItem.review.webPreview.loading",
                                defaultValue: "サイトを読み込み中…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            )
    }

    private var placeholderThumbnail: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.systemGray5))
            .overlay(
                Image(systemName: "cart")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            )
    }

    /// Full-width buttons stacked vertically in the review card.
    @ViewBuilder
    private func reviewButtons(_ dialog: AddItemViewModel.RegistrationReviewDialog) -> some View {
        VStack(spacing: 8) {
            switch dialog.kind {
            case .detected:
                // Primary: confirm price and return to form to set memo/conditions
                Button {
                    viewModel.confirmPrice()
                } label: {
                    Text(String(localized: "addItem.review.detected.confirm",
                                defaultValue: "この価格で登録"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                // Secondary: retry (1st attempt) or give-up (2nd attempt)
                if dialog.isLastAttempt {
                    Button {
                        viewModel.reviewDialog = nil
                        dismiss()
                    } label: {
                        Text(String(localized: "addItem.review.giveUp",
                                    defaultValue: "検出不可なため閉じる"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                } else {
                    Button {
                        if let url = viewModel.beginAlternativeVerification() {
                            manualCaptureTarget = ManualCaptureTarget(url: url)
                        }
                    } label: {
                        Text(String(localized: "addItem.review.detected.retry",
                                    defaultValue: "別の方法で確認"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                // Cancel (stays on sheet)
                Button {
                    viewModel.reviewDialog = nil
                } label: {
                    Text(String(localized: "action.cancel", defaultValue: "キャンセル"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            case .failed:
                Button {
                    viewModel.reviewDialog = nil
                    dismiss()
                } label: {
                    Text(String(localized: "addItem.review.giveUp",
                                defaultValue: "検出不可なため閉じる"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.reviewDialog = nil
                } label: {
                    Text(String(localized: "action.cancel", defaultValue: "キャンセル"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                TextField(
                    "addItem.url.placeholder",
                    text: $viewModel.urlText
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .url)
                .onSubmit { focusedField = .title }

                if clipboardHasURL {
                    Button {
                        viewModel.pasteFromClipboard()
                    } label: {
                        Label("addItem.pasteURL", systemImage: "doc.on.clipboard")
                            .font(.subheadline)
                    }
                }
            } header: {
                Text("addItem.section.url")
            }

            Section {
                TextField(
                    "addItem.title.placeholder",
                    text: $viewModel.titleText
                )
                .submitLabel(.next)
                .focused($focusedField, equals: .title)
                .onSubmit { focusedField = .category }
            } header: {
                Text("addItem.section.title")
            } footer: {
                Text("addItem.title.hint")
            }

            Section {
                TextField(
                    "addItem.category.placeholder",
                    text: $viewModel.categoryText
                )
                .submitLabel(.next)
                .focused($focusedField, equals: .category)
                .onSubmit { focusedField = .memo }

                if !existingCategories.isEmpty {
                    Menu {
                        ForEach(existingCategories, id: \.self) { category in
                            Button {
                                viewModel.categoryText = category
                            } label: {
                                Text(verbatim: category)
                            }
                        }
                    } label: {
                        Label("addItem.category.pickExisting", systemImage: "folder")
                            .font(.subheadline)
                    }
                }
            } header: {
                Text("addItem.section.category")
            }

            Section {
                TextField(
                    "addItem.memo.placeholder",
                    text: $viewModel.memo
                )
                .submitLabel(.done)
                .focused($focusedField, equals: .memo)
                .onSubmit { focusedField = nil }
            } header: {
                Text("addItem.section.notes")
            }

            Section {
                Picker(
                    "addItem.notification.type",
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
                        "addItem.notification.value.placeholder",
                        text: $viewModel.notificationConditionValueText
                    )
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .notificationValue)

                    Text(notificationUnitLabel(for: viewModel.notificationConditionType))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("addItem.section.notification")
            } footer: {
                Text("addItem.notification.hint")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Keyboard dismiss button placed directly on the Form so it reliably
        // appears for all keyboard types (.URL, .decimalPad, .default).
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "action.keyboardDone", defaultValue: "完了")) {
                    focusedField = nil
                }
            }
        }
    }

    // MARK: - Overlays

    private var registerButtonOverlay: some View {
        VStack {
            Button {
                focusedField = nil
                Task { await viewModel.register(context: viewContext) }
            } label: {
                Text("addItem.register")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 46)
                    .background(
                        viewModel.canRegister ? Color.accentColor : Color.secondary.opacity(0.45),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canRegister)
            .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)
        }
        .padding(.bottom, 12)
    }

    /// Shown after the user confirms the detected price in the review card.
    /// Lets them adjust memo/conditions before the final save.
    private var confirmRegistrationButton: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(String(localized: "addItem.review.priceConfirmed",
                            defaultValue: "価格確認済み"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.confirmPreparedRegistration(context: viewContext)
            } label: {
                Text(String(localized: "addItem.review.finalRegister",
                            defaultValue: "登録する"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 46)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)
        }
        .padding(.bottom, 12)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.4)
                Text("addItem.registering")
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Helpers

    private var existingCategories: [String] {
        let values = existingItems.compactMap { $0.itemCategory }
        return Array(Set(values)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func refreshClipboardAvailability() {
        let pasteboard = UIPasteboard.general
        // Use `hasURLs`/`hasStrings` (fast metadata query) as a gate before reading
        // actual content. Reading `pasteboard.url` or `pasteboard.string` directly can
        // trigger iOS's paste-notification banner, which causes a brief UI stutter.
        if pasteboard.hasURLs {
            clipboardHasURL = true
            return
        }
        guard pasteboard.hasStrings else {
            clipboardHasURL = false
            return
        }
        if let text = pasteboard.string {
            clipboardHasURL = URLNormalizer.normalize(text) != nil
            return
        }
        clipboardHasURL = false
    }

    private func notificationUnitLabel(for type: NotificationConditionType) -> LocalizedStringKey {
        switch type {
        case .percentage: return "%"
        case .amount, .targetPrice: return "currency.jpy.unit"
        }
    }

    private var showFloatingRegisterButton: Bool {
        !viewModel.isRegistering && focusedField == nil && viewModel.reviewDialog == nil
    }

    private var bottomFloatingInset: CGFloat {
        showFloatingRegisterButton ? 78 : 0
    }
}

// MARK: - Preview

#Preview {
    AddItemSheet()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
