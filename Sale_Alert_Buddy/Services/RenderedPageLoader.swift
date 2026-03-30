import Foundation
import UIKit
import WebKit

@MainActor
protocol RenderedPageLoading {
    func load(url: URL) async -> RenderedPageSnapshot?
}

struct RenderedPageSnapshot: Sendable {
    let html: String
    let finalURL: URL
    let visiblePriceResult: PriceResult?
}

@MainActor
final class WebKitRenderedPageLoader: RenderedPageLoading {

    static let shared = WebKitRenderedPageLoader()

    fileprivate static let viewportSize = CGSize(width: 390, height: 844)

    func load(url: URL) async -> RenderedPageSnapshot? {
        guard let window = Self.captureWindow else { return nil }

        if let snapshot = await LoadSession(window: window, requestedURL: url).start() {
            return snapshot
        }

        return await LoadSession(window: window, requestedURL: url).start()
    }
}

@MainActor
private final class LoadSession: NSObject, WKNavigationDelegate {

    private static let timeoutSeconds: TimeInterval = 20

    private let window: UIWindow
    private let requestedURL: URL
    private var continuation: CheckedContinuation<RenderedPageSnapshot?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var webView: WKWebView?

    init(window: UIWindow, requestedURL: URL) {
        self.window = window
        self.requestedURL = requestedURL
    }

    func start() async -> RenderedPageSnapshot? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.mediaTypesRequiringUserActionForPlayback = .all
            WebPreviewSanitizer.configure(config)

            let webView = WKWebView(
                frame: CGRect(origin: .zero, size: WebKitRenderedPageLoader.viewportSize),
                configuration: config
            )
            webView.navigationDelegate = self
            webView.customUserAgent = WebPreviewSanitizer.mobileSafariUserAgent
            webView.backgroundColor = .systemBackground
            webView.isOpaque = true
            webView.alpha = 0.001
            webView.scrollView.contentInsetAdjustmentBehavior = .never

            window.addSubview(webView)
            self.webView = webView
            webView.load(
                URLRequest(
                    url: requestedURL,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: 18
                )
            )

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
                self?.finish(with: nil)
            }
        }
    }

    private func finish(with snapshot: RenderedPageSnapshot?) {
        guard let continuation else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil

        self.continuation = nil
        continuation.resume(returning: snapshot)
    }

    private func waitForRenderedContent(attempt: Int = 0) {
        let delay = 0.25 + (Double(attempt) * 0.28)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let webView = self.webView else { return }

            webView.evaluateJavaScript(
                WebPreviewSanitizer.readinessScript(priceDigits: "")
            ) { [weak self] result, _ in
                guard let self else { return }
                let isReady = (result as? Bool) ?? false
                if isReady {
                    self.extractSnapshot()
                } else if attempt < 8 {
                    self.waitForRenderedContent(attempt: attempt + 1)
                } else {
                    self.finish(with: nil)
                }
            }
        }
    }

    private func extractSnapshot() {
        webView?.asyncEvaluateJavaScript(
            WebPreviewSanitizer.visiblePriceProbeScript(priceDigits: nil)
        ) { [weak self] payload in
            guard let self else { return }
            let visiblePrice = self.parsedVisiblePrice(from: payload)

            self.webView?.asyncEvaluateJavaScript("document.documentElement.outerHTML") { [weak self] html in
                guard let self else { return }

                let finalURL = self.webView?.url ?? self.requestedURL
                let snapshot = RenderedPageSnapshot(
                    html: html ?? "",
                    finalURL: finalURL,
                    visiblePriceResult: visiblePrice
                )

                if snapshot.html.isEmpty && snapshot.visiblePriceResult == nil {
                    self.finish(with: nil)
                } else {
                    self.finish(with: snapshot)
                }
            }
        }
    }

    private func parsedVisiblePrice(from payload: String?) -> PriceResult? {
        WebPreviewSanitizer.parseVisiblePriceResult(from: payload)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForRenderedContent()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !Self.isBenignNavigationError(error) else { return }
        finish(with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Self.isBenignNavigationError(error) else { return }
        finish(with: nil)
    }

    private static func isBenignNavigationError(_ error: Error) -> Bool {
        (error as NSError).code == NSURLErrorCancelled
    }
}

private extension WebKitRenderedPageLoader {
    static var captureWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first
    }
}

private extension WKWebView {
    func asyncEvaluateJavaScript(_ script: String, completion: @escaping (String?) -> Void) {
        evaluateJavaScript(script) { result, _ in
            completion(result as? String)
        }
    }
}
