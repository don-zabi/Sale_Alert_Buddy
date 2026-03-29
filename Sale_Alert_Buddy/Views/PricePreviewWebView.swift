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
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.backgroundColor = UIColor.systemBackground
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
            injectReadOnlyStyles(into: webView)
            if let price = priceDecimal {
                injectPriceHighlight(into: webView, price: price)
            }
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

        /// Disables pointer events on all interactive elements so the page looks
        /// and feels read-only. Buttons, links, and form controls still render
        /// normally but cannot be tapped.
        private func injectReadOnlyStyles(into webView: WKWebView) {
            let js = """
            (function() {
                var s = document.createElement('style');
                s.textContent = [
                    'a, button, input, select, textarea, [role="button"], [role="link"]',
                    '{ pointer-events: none !important; cursor: default !important; }'
                ].join(' ');
                document.head.appendChild(s);
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private func injectPriceHighlight(into webView: WKWebView, price: Decimal) {
            let priceString = (price as NSDecimalNumber).stringValue
            let digitsOnly = priceString.filter(\.isNumber)

            let js = """
            (function() {
                var digits = "\(digitsOnly)";
                var allNodes = document.querySelectorAll(
                    'span, div, p, strong, b, em, label, td, li, [class*="price"], [id*="price"], [data-price]'
                );
                var best = null;
                var bestScore = -1;
                for (var i = 0; i < allNodes.length; i++) {
                    var el = allNodes[i];
                    var style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden') continue;
                    var text = el.innerText || el.textContent || '';
                    var nodeDigits = text.replace(/\\D/g, '');
                    if (nodeDigits.includes(digits) && text.length < 60) {
                        var score = 1000 - text.trim().length;
                        if (score > bestScore) {
                            bestScore = score;
                            best = el;
                        }
                    }
                }
                if (best) {
                    best.style.backgroundColor = '#FFF176';
                    best.style.outline = '2px solid #FF9800';
                    best.style.borderRadius = '3px';
                    best.scrollIntoView({ behavior: 'smooth', block: 'center' });
                }
            })();
            """

            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
