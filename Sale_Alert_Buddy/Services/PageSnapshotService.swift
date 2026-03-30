import UIKit
import WebKit

/// Loads a product page in an off-screen WKWebView, scrolls to the price element,
/// and captures a snapshot of the visible viewport.
///
/// The WKWebView is placed on-screen with `alpha = 0.001` so Core Animation
/// includes it in the render pipeline — a fully off-screen view produces a blank
/// snapshot because UIKit skips compositing views outside the window bounds.
///
/// The snapshot is taken at the page's natural zoom level (no scaling) with
/// the price element centred via `scrollIntoView({ behavior:'instant', block:'center' })`.
/// Nothing is written to disk; the WKWebView is removed after capture.
@MainActor
final class PageSnapshotService: NSObject {

    static let shared = PageSnapshotService()

    /// Viewport that matches a typical iPhone Pro screen.
    private static let viewportSize = CGSize(width: 390, height: 844)

    /// Total time budget from load-start to snapshot-taken.
    private static let timeoutSeconds: TimeInterval = 8
    /// Retry highlight injection because SPAs often render the price block late.
    private static let highlightRetryDelays: [TimeInterval] = [0.0, 0.28, 0.62, 1.05]
    /// Retry once or twice when WebKit gives us a compositor placeholder frame.
    private static let snapshotRetryDelays: [TimeInterval] = [0.25, 0.45]

    private var webView: WKWebView?
    private var completion: ((UIImage?) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var priceDigits: String = ""

    // MARK: - Public

    /// Loads `url` in an invisible WKWebView, highlights the element containing
    /// `priceDecimal`, and returns a snapshot of the visible viewport.
    /// Returns `nil` on load failure, bot-block, or timeout.
    func capture(url: URL, priceDecimal: Decimal) async -> UIImage? {
        cancelCurrent()

        return await withCheckedContinuation { continuation in
            guard let window = Self.captureWindow else {
                continuation.resume(returning: nil)
                return
            }

            priceDigits = (priceDecimal as NSDecimalNumber)
                .stringValue
                .filter(\.isNumber)
            completion = { continuation.resume(returning: $0) }

            let config = WKWebViewConfiguration()
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.websiteDataStore = .nonPersistent()
            WebPreviewSanitizer.configure(config)

            let wv = WKWebView(
                frame: CGRect(origin: .zero, size: Self.viewportSize),
                configuration: config
            )
            wv.navigationDelegate = self
            wv.customUserAgent = WebPreviewSanitizer.mobileSafariUserAgent
            wv.backgroundColor = .systemBackground
            wv.isOpaque = true
            wv.scrollView.contentInsetAdjustmentBehavior = .never
            // alpha = 0.001 keeps the view "on-screen" in Core Animation's eyes
            // so the GPU actually rasterises it — 0.0 or isHidden produce blank snapshots.
            wv.alpha = 0.001

            window.addSubview(wv)
            webView = wv
            wv.load(URLRequest(url: url,
                               cachePolicy: .returnCacheDataElseLoad,
                               timeoutInterval: 10))

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
                self?.finish(with: nil)
            }
        }
    }

    func cancelCapture() {
        cancelCurrent()
    }

    // MARK: - Private helpers

    private func cancelCurrent() {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        let c = completion
        completion = nil
        c?(nil)
    }

    private func finish(with image: UIImage?) {
        guard completion != nil else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        let c = completion
        completion = nil
        let validatedImage = image.flatMap { PreviewImageValidator.isLikelyBlank($0) ? nil : $0 }
        c?(validatedImage)
    }

    /// Polls until the page body has meaningful content (JS SPAs need extra time),
    /// then injects the price highlight and captures the snapshot.
    private func waitForContentThenCapture(_ webView: WKWebView, attempt: Int = 0) {
        let delay = 0.15 + Double(attempt) * 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let wv = self.webView else { return }

            wv.evaluateJavaScript(
                WebPreviewSanitizer.readinessScript(priceDigits: self.priceDigits)
            ) { [weak self] result, _ in
                guard let self else { return }
                let isReady = (result as? Bool) ?? false
                if isReady {
                    self.injectAndCapture(wv)
                } else if attempt < 5 {
                    self.waitForContentThenCapture(wv, attempt: attempt + 1)
                } else {
                    self.finish(with: nil)
                }
            }
        }
    }

    private func injectAndCapture(_ webView: WKWebView) {
        attemptHighlightAndCapture(webView, attempt: 0)
    }

    private func attemptHighlightAndCapture(_ webView: WKWebView, attempt: Int) {
        webView.evaluateJavaScript(
            WebPreviewSanitizer.postLoadScript(priceDigits: priceDigits)
        ) { [weak self] result, _ in
            guard let self, self.webView != nil else { return }

            if (result as? Bool) == true {
                // One run-loop tick for Core Animation to present the updated frame
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, let wv = self.webView else { return }
                    self.captureSnapshot(from: wv)
                }
                return
            }

            guard attempt < Self.highlightRetryDelays.count - 1 else {
                self.finish(with: nil)
                return
            }

            let retryDelay = Self.highlightRetryDelays[attempt + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                guard let self, let currentWebView = self.webView, currentWebView === webView else { return }
                self.attemptHighlightAndCapture(webView, attempt: attempt + 1)
            }
        }
    }

    private func captureSnapshot(from webView: WKWebView, attempt: Int = 0) {
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = true

        webView.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self else { return }
            guard let currentWebView = self.webView, currentWebView === webView else { return }

            if let image, !PreviewImageValidator.isLikelyBlank(image) {
                self.finish(with: image)
                return
            }

            guard attempt < Self.snapshotRetryDelays.count else {
                self.finish(with: nil)
                return
            }

            let retryDelay = Self.snapshotRetryDelays[attempt]
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                guard let self, let currentWebView = self.webView, currentWebView === webView else { return }
                self.captureSnapshot(from: webView, attempt: attempt + 1)
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension PageSnapshotService: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForContentThenCapture(webView)
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        finish(with: nil)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        finish(with: nil)
    }
}

private extension PageSnapshotService {
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
