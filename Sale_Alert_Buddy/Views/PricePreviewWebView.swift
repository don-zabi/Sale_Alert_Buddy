import SwiftUI
import WebKit
import UIKit

/// Inline WKWebView that loads a product page and highlights the price element.
///
/// After page load completes, JavaScript scrolls to and highlights the DOM
/// element whose text content most closely matches `priceDecimal`.
struct PricePreviewWebView: UIViewRepresentable {

    let url: URL
    /// Raw Decimal price used to locate the price element in the page DOM.
    let priceDecimal: Decimal?
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, priceDecimal: priceDecimal)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.websiteDataStore = .default()
        WebPreviewSanitizer.configure(config)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = UIColor.systemBackground
        webView.isOpaque = true
        webView.customUserAgent = WebPreviewSanitizer.mobileSafariUserAgent
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        webView.load(request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {

        @Binding var isLoading: Bool
        let priceDecimal: Decimal?

        init(isLoading: Binding<Bool>, priceDecimal: Decimal?) {
            _isLoading = isLoading
            self.priceDecimal = priceDecimal
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            switch navigationAction.navigationType {
            case .linkActivated, .formSubmitted, .formResubmitted, .backForward:
                // Block all user-initiated navigation — this is a read-only preview.
                decisionHandler(.cancel)
            default:
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            applyPreviewDecorations(into: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            isLoading = false
        }

        // MARK: - JS injection

        private func applyPreviewDecorations(into webView: WKWebView) {
            let digitsOnly = priceDecimal.map {
                ($0 as NSDecimalNumber).stringValue.filter(\.isNumber)
            }
            let script = WebPreviewSanitizer.postLoadScript(priceDigits: digitsOnly)
            for delay in [0.0, 0.35, 0.9, 1.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                    webView?.evaluateJavaScript(script, completionHandler: nil)
                }
            }
        }
    }
}
