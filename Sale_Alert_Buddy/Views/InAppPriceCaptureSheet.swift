import SwiftUI
import WebKit

struct InAppPriceCaptureResponse: Sendable {
    let shouldDismiss: Bool
    let message: String
}

struct InAppPriceCaptureSheet: View {

    let initialURL: URL
    let title: String
    let onCapturedPage: @MainActor (String, URL) async -> InAppPriceCaptureResponse

    @Environment(\.dismiss) private var dismiss
    @State private var browser: InAppPriceCaptureBrowser
    @State private var isCapturing: Bool = false
    @State private var statusMessage: String?
    @State private var didAttemptAutomaticCapture = false
    @State private var showingStatusAlert = false

    init(
        initialURL: URL,
        title: String,
        onCapturedPage: @escaping @MainActor (String, URL) async -> InAppPriceCaptureResponse
    ) {
        self.initialURL = initialURL
        self.title = title
        self.onCapturedPage = onCapturedPage
        _browser = State(initialValue: InAppPriceCaptureBrowser(initialURL: initialURL))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                InAppBrowserWebView(
                    browser: browser,
                    onPageReady: triggerAutomaticCaptureIfNeeded
                )
                .ignoresSafeArea(edges: .bottom)

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
                    localized: "manualCapture.instructions",
                    defaultValue: "ページが表示されたら価格取得を押してください。検証やログインが必要な場合は完了後に再取得できます。"
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

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

    private func triggerAutomaticCaptureIfNeeded() {
        guard !didAttemptAutomaticCapture else { return }
        didAttemptAutomaticCapture = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            await capturePrice()
        }
    }

    private func capturePrice() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            try await browser.syncCookiesToSharedStorage()
            let snapshot = try await browser.snapshot()
            let response = await onCapturedPage(snapshot.html, snapshot.url)
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
}

@MainActor
@Observable
final class InAppPriceCaptureBrowser {

    struct Snapshot {
        let html: String
        let url: URL
    }

    let initialURL: URL
    let webView: WKWebView
    var isLoading: Bool = true
    var currentURL: URL?

    init(initialURL: URL) {
        self.initialURL = initialURL

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        self.webView = webView
        self.currentURL = initialURL
    }

    func loadIfNeeded() {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: initialURL))
    }

    func reload() {
        if webView.url == nil {
            loadIfNeeded()
        } else {
            webView.reload()
        }
    }

    func snapshot() async throws -> Snapshot {
        let htmlValue = try await webView.asyncEvaluateJavaScript("document.documentElement.outerHTML")
        guard let html = htmlValue as? String, !html.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }

        return Snapshot(
            html: html,
            url: webView.url ?? currentURL ?? initialURL
        )
    }

    func syncCookiesToSharedStorage() async throws {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

private struct InAppBrowserWebView: UIViewRepresentable {

    let browser: InAppPriceCaptureBrowser
    let onPageReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser, onPageReady: onPageReady)
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
        private let onPageReady: () -> Void

        init(browser: InAppPriceCaptureBrowser, onPageReady: @escaping () -> Void) {
            self.browser = browser
            self.onPageReady = onPageReady
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser.isLoading = true
            browser.currentURL = webView.url ?? browser.initialURL
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.isLoading = false
            browser.currentURL = webView.url ?? browser.initialURL
            onPageReady()
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
