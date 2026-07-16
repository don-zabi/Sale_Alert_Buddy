import SwiftUI
import WebKit

struct InAppPriceCaptureResponse: Sendable {
    let shouldDismiss: Bool
    let message: String
}

struct InAppCapturedPage {
    let html: String
    let url: URL
    let visiblePriceResult: PriceResult?
    let visiblePriceCandidates: [PriceCandidate]
    let selectedPriceCandidate: PriceCandidate?
    let previewImage: UIImage?

    init(
        html: String,
        url: URL,
        visiblePriceResult: PriceResult? = nil,
        visiblePriceCandidates: [PriceCandidate] = [],
        selectedPriceCandidate: PriceCandidate? = nil,
        previewImage: UIImage?
    ) {
        self.html = html
        self.url = url
        self.visiblePriceResult = visiblePriceResult
        self.visiblePriceCandidates = visiblePriceCandidates
        self.selectedPriceCandidate = selectedPriceCandidate
        self.previewImage = previewImage
    }
}

struct InAppPriceCaptureSheet: View {

    let initialURL: URL
    let title: String
    let onCapturedPage: @MainActor (InAppCapturedPage) async -> InAppPriceCaptureResponse

    @Environment(\.dismiss) private var dismiss
    @State private var browser: InAppPriceCaptureBrowser
    @State private var isCapturing: Bool = false
    @State private var isSelectingPrice: Bool = false
    @State private var statusMessage: String?
    @State private var showingStatusAlert = false

    init(
        initialURL: URL,
        title: String,
        onCapturedPage: @escaping @MainActor (InAppCapturedPage) async -> InAppPriceCaptureResponse
    ) {
        self.initialURL = initialURL
        self.title = title
        self.onCapturedPage = onCapturedPage
        _browser = State(initialValue: InAppPriceCaptureBrowser(initialURL: initialURL))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                InAppBrowserWebView(browser: browser)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay {
                        if isSelectingPrice {
                            priceSelectionGuide
                        }
                    }

                controlsOverlay
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                String(
                    localized: "manualCapture.alert.title",
                    defaultValue: "価格を取得できませんでした"
                ),
                isPresented: $showingStatusAlert
            ) {
                Button("action.ok", role: .cancel) {}
            } message: {
                Text(statusMessage ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "action.close", defaultValue: "Close")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if browser.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var controlsOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                String(
                    localized: "manualCapture.instructions.positionAware",
                    defaultValue: "ページが表示されたら価格を取得してください。価格が多いページでは価格位置を指定すると、その場所のDOMを優先して判定します。"
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if isSelectingPrice {
                Text(
                    String(
                        localized: "manualCapture.selecting",
                        defaultValue: "中央の枠に価格を合わせてから「中央の価格を指定」を押してください。"
                    )
                )
                .font(.footnote)
                .foregroundStyle(.primary)
            } else if let selectedPriceCandidate = browser.selectedPriceCandidate {
                Text(
                    String(
                        format: String(
                            localized: "manualCapture.selectedPrice",
                            defaultValue: "指定した価格: %@"
                        ),
                        NotificationService.formatPrice(
                            selectedPriceCandidate.amount,
                            currency: selectedPriceCandidate.currency
                        )
                    )
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            }

            if let statusMessage, !statusMessage.isEmpty {
                Text(verbatim: statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        await capturePrice()
                    }
                } label: {
                    Label(
                        String(localized: "manualCapture.button", defaultValue: "価格を取得"),
                        systemImage: "tag"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCapturing)

                Button {
                    Task {
                        await handleSelectionButton()
                    }
                } label: {
                    Label(
                        isSelectingPrice
                            ? String(localized: "manualCapture.select.confirm", defaultValue: "中央の価格を指定")
                            : String(localized: "manualCapture.select.start", defaultValue: "価格位置を指定"),
                        systemImage: isSelectingPrice ? "scope" : "viewfinder"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isCapturing || browser.isLoading)

                Button {
                    browser.reload()
                } label: {
                    Label(
                        String(localized: "manualCapture.reload", defaultValue: "再読込"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isCapturing)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var priceSelectionGuide: some View {
        GeometryReader { proxy in
            let center = browser.selectionGuideCenter(in: proxy.size)

            ZStack {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .foregroundStyle(.orange)
                    .frame(width: 180, height: 76)
                    .position(center)

                Text(
                    String(
                        localized: "manualCapture.select.guide",
                        defaultValue: "この枠に価格を合わせる"
                    )
                )
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .position(x: center.x, y: center.y - 62)
            }
            .allowsHitTesting(false)
        }
    }

    private func capturePrice() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            if isSelectingPrice {
                let didSelect = await confirmSelectionAtGuide()
                guard didSelect else { return }
            }
            try await browser.syncCookiesToSharedStorage()
            let snapshot = try await browser.snapshot()
            let response = await onCapturedPage(snapshot)
            if response.shouldDismiss {
                dismiss()
            } else {
                statusMessage = response.message
                showingStatusAlert = true
            }
        } catch {
            statusMessage = String(
                format: String(
                    localized: "manualCapture.snapshot.failed",
                    defaultValue: "ページ内容を取得できませんでした: %@"
                ),
                error.localizedDescription
            )
            showingStatusAlert = true
        }
    }

    private func handleSelectionButton() async {
        if isSelectingPrice {
            _ = await confirmSelectionAtGuide()
        } else {
            browser.selectedPriceCandidate = nil
            isSelectingPrice = true
            statusMessage = String(
                localized: "manualCapture.select.hint",
                defaultValue: "スクロールして、中央の枠に価格を合わせてください。"
            )
        }
    }

    @discardableResult
    private func confirmSelectionAtGuide() async -> Bool {
        do {
            guard let candidate = try await browser.pickPriceCandidateAtGuidePoint() else {
                statusMessage = String(
                    localized: "manualCapture.select.notFound",
                    defaultValue: "枠の近くで価格候補を見つけられませんでした。価格表示を枠の中央に合わせて再度お試しください。"
                )
                return false
            }

            browser.selectedPriceCandidate = candidate
            isSelectingPrice = false
            statusMessage = String(
                format: String(
                    localized: "manualCapture.select.success",
                    defaultValue: "指定した価格候補: %@"
                ),
                NotificationService.formatPrice(candidate.amount, currency: candidate.currency)
            )
            return true
        } catch {
            statusMessage = String(
                format: String(
                    localized: "manualCapture.snapshot.failed",
                    defaultValue: "ページ内容を取得できませんでした: %@"
                ),
                error.localizedDescription
            )
            return false
        }
    }
}

@MainActor
@Observable
final class InAppPriceCaptureBrowser {

    static let selectionGuideVerticalRatio: CGFloat = 0.36

    let initialURL: URL
    let webView: WKWebView
    var isLoading: Bool = true
    var currentURL: URL?
    var selectedPriceCandidate: PriceCandidate?

    init(initialURL: URL) {
        self.initialURL = initialURL

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        WebPreviewSanitizer.configure(configuration)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = WebPreviewSanitizer.mobileSafariUserAgent
        self.webView = webView
        self.currentURL = initialURL
    }

    func loadIfNeeded() {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: initialURL))
    }

    func reload() {
        selectedPriceCandidate = nil
        if webView.url == nil {
            loadIfNeeded()
        } else {
            webView.reload()
        }
    }

    func snapshot() async throws -> InAppCapturedPage {
        let probedCandidates = (try? await probeVisiblePriceCandidates()) ?? []
        let visiblePriceCandidates = mergedVisibleCandidates(
            selected: selectedPriceCandidate,
            candidates: probedCandidates
        )
        let visiblePriceResult = (selectedPriceCandidate ?? visiblePriceCandidates.first).map {
            PriceResult(
                price: $0.amount,
                currency: $0.currency,
                extractMethod: $0.extractMethod,
                confidence: $0.confidence,
                confidenceLevel: .medium,
                sourceType: $0.sourceType,
                anchor: $0.anchor
            )
        }
        let htmlValue = try await webView.asyncEvaluateJavaScript("document.documentElement.outerHTML")
        guard let html = htmlValue as? String, !html.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }

        return InAppCapturedPage(
            html: html,
            url: webView.url ?? currentURL ?? initialURL,
            visiblePriceResult: visiblePriceResult,
            visiblePriceCandidates: visiblePriceCandidates,
            selectedPriceCandidate: selectedPriceCandidate,
            previewImage: await webView.snapshotImage()
        )
    }

    private func probeVisiblePriceCandidates() async throws -> [PriceCandidate] {
        let payload = try await webView.asyncEvaluateJavaScript(
            WebPreviewSanitizer.standaloneVisiblePriceProbeScript(priceDigits: nil)
        ) as? String
        return WebPreviewSanitizer.parseVisiblePriceCandidates(from: payload)
    }

    func pickPriceCandidateAtGuidePoint() async throws -> PriceCandidate? {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }

        let guideCenter = selectionGuideCenter(in: webView.bounds.size)
        let payload = try await webView.asyncEvaluateJavaScript(
            WebPreviewSanitizer.pointSelectionScript(
                pointX: guideCenter.x,
                pointY: guideCenter.y
            )
        ) as? String

        return WebPreviewSanitizer.parseVisiblePriceCandidates(from: payload).first
    }

    func selectionGuideCenter(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2,
            y: size.height * Self.selectionGuideVerticalRatio
        )
    }

    func syncCookiesToSharedStorage() async throws {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private func mergedVisibleCandidates(
        selected: PriceCandidate?,
        candidates: [PriceCandidate]
    ) -> [PriceCandidate] {
        var merged: [PriceCandidate] = []
        var seen = Set<String>()

        func append(_ candidate: PriceCandidate) {
            let key = "\(candidate.amountKey)|\(candidate.anchorKey)"
            guard seen.insert(key).inserted else { return }
            merged.append(candidate)
        }

        if let selected {
            append(selected)
        }

        for candidate in candidates {
            append(candidate)
        }

        return merged
    }
}

private struct InAppBrowserWebView: UIViewRepresentable {

    let browser: InAppPriceCaptureBrowser

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeUIView(context: Context) -> WKWebView {
        browser.webView.navigationDelegate = context.coordinator
        browser.loadIfNeeded()
        return browser.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.navigationDelegate = context.coordinator
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let browser: InAppPriceCaptureBrowser

        init(browser: InAppPriceCaptureBrowser) {
            self.browser = browser
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser.isLoading = true
            browser.currentURL = webView.url ?? browser.initialURL
            browser.selectedPriceCandidate = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.isLoading = false
            browser.currentURL = webView.url ?? browser.initialURL
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            browser.isLoading = false
            browser.currentURL = webView.url ?? browser.initialURL
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            browser.isLoading = false
            browser.currentURL = webView.url ?? browser.initialURL
        }
    }
}

private extension WKWebView {
    func asyncEvaluateJavaScript(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func snapshotImage() async -> UIImage? {
        await withCheckedContinuation { continuation in
            takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}
