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

    /// Looks like Mobile Safari to avoid bot-detection that blank-pages automated agents.
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/17.0 Mobile/15E148 Safari/604.1"

    /// Total time budget from load-start to snapshot-taken.
    private static let timeoutSeconds: TimeInterval = 15

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
            priceDigits = (priceDecimal as NSDecimalNumber)
                .stringValue
                .filter(\.isNumber)
            completion = { continuation.resume(returning: $0) }

            let config = WKWebViewConfiguration()
            config.mediaTypesRequiringUserActionForPlayback = .all

            let wv = WKWebView(
                frame: CGRect(origin: .zero, size: Self.viewportSize),
                configuration: config
            )
            wv.navigationDelegate = self
            wv.customUserAgent = Self.userAgent
            // alpha = 0.001 keeps the view "on-screen" in Core Animation's eyes
            // so the GPU actually rasterises it — 0.0 or isHidden produce blank snapshots.
            wv.alpha = 0.001

            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows.first {
                window.addSubview(wv)
            }

            webView = wv
            wv.load(URLRequest(url: url,
                               cachePolicy: .returnCacheDataElseLoad,
                               timeoutInterval: 15))

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
                self?.finish(with: nil)
            }
        }
    }

    // MARK: - Private helpers

    private func cancelCurrent() {
        timeoutTask?.cancel()
        timeoutTask = nil
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
        webView?.removeFromSuperview()
        webView = nil
        let c = completion
        completion = nil
        c?(image)
    }

    /// Polls until the page body has meaningful content (JS SPAs need extra time),
    /// then injects the price highlight and captures the snapshot.
    private func waitForContentThenCapture(_ webView: WKWebView, attempt: Int = 0) {
        // Delay grows on each retry: 0.5 s, 0.8 s, 1.1 s, 1.4 s
        let delay = 0.5 + Double(attempt) * 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let wv = self.webView else { return }

            wv.evaluateJavaScript(
                "document.body ? document.body.innerHTML.length : 0"
            ) { [weak self] result, _ in
                guard let self else { return }
                let length = (result as? Int) ?? 0
                // Retry up to 4 times (≈ 3.8 s total wait) for slow JS frameworks
                if length < 500 && attempt < 4 {
                    self.waitForContentThenCapture(wv, attempt: attempt + 1)
                } else {
                    self.injectAndCapture(wv)
                }
            }
        }
    }

    private func injectAndCapture(_ webView: WKWebView) {
        let digits = priceDigits
        let js = """
        (function() {
            // Make all interactive elements inert so the screenshot looks read-only
            var s = document.createElement('style');
            s.textContent = 'a,button,input,select,textarea,[role="button"]{pointer-events:none!important}';
            document.head.appendChild(s);

            // Find the best-matching price element
            var digits = "\(digits)";
            var nodes = document.querySelectorAll(
                'span,div,p,strong,b,em,label,td,li,[class*="price"],[id*="price"],[data-price]'
            );
            var best = null, bestScore = -1;
            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var cs = window.getComputedStyle(el);
                if (cs.display === 'none' || cs.visibility === 'hidden') continue;
                var txt = (el.innerText || el.textContent || '').trim();
                var nd = txt.replace(/\\D/g, '');
                if (nd.includes(digits) && txt.length < 60) {
                    var score = 1000 - txt.length;
                    if (score > bestScore) { bestScore = score; best = el; }
                }
            }
            if (best) {
                best.style.backgroundColor = '#FFF176';
                best.style.outline = '2px solid #FF9800';
                best.style.borderRadius = '3px';
                // 'instant' so position is applied synchronously before the snapshot
                best.scrollIntoView({ behavior: 'instant', block: 'center' });
            }
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] _, _ in
            guard let self, let wv = self.webView else { return }
            // One run-loop tick for Core Animation to present the updated frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let wv = self.webView else { return }
                let cfg = WKSnapshotConfiguration()
                cfg.afterScreenUpdates = true
                wv.takeSnapshot(with: cfg) { [weak self] image, _ in
                    self?.finish(with: image)
                }
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
        finish(with: nil)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(with: nil)
    }
}
