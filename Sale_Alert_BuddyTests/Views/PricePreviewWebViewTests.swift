import Testing
import WebKit
@testable import Sale_Alert_Buddy

// MARK: - PricePreviewWebView.Coordinator Tests

/// Tests for the read-only navigation guard in the price preview coordinator.
///
/// The preview is intentionally non-interactive: the user should only be able
/// to scroll and read the page — not click links, submit forms, or navigate away.
@Suite("PricePreviewWebView.Coordinator – navigation policy")
@MainActor
struct PricePreviewWebViewTests {

    private func makeCoordinator() -> PricePreviewWebView.Coordinator {
        var loading = false
        let binding = Binding(get: { loading }, set: { loading = $0 })
        return PricePreviewWebView.Coordinator(isLoading: binding, priceDecimal: Decimal(1980))
    }

    private func makeWebView() -> WKWebView {
        WKWebView(frame: .zero)
    }

    // MARK: - Navigation policy

    @Test("link taps are cancelled")
    func linkTapCancelled() async {
        let coordinator = makeCoordinator()
        let webView = makeWebView()

        var policy: WKNavigationActionPolicy = .allow
        let action = MockNavigationAction(type: .linkActivated)

        await withCheckedContinuation { continuation in
            coordinator.webView(webView, decidePolicyFor: action) { result in
                policy = result
                continuation.resume()
            }
        }

        #expect(policy == .cancel)
    }

    @Test("form submissions are cancelled")
    func formSubmitCancelled() async {
        let coordinator = makeCoordinator()
        let webView = makeWebView()

        var policy: WKNavigationActionPolicy = .allow
        let action = MockNavigationAction(type: .formSubmitted)

        await withCheckedContinuation { continuation in
            coordinator.webView(webView, decidePolicyFor: action) { result in
                policy = result
                continuation.resume()
            }
        }

        #expect(policy == .cancel)
    }

    @Test("form resubmissions are cancelled")
    func formResubmitCancelled() async {
        let coordinator = makeCoordinator()
        let webView = makeWebView()

        var policy: WKNavigationActionPolicy = .allow
        let action = MockNavigationAction(type: .formResubmitted)

        await withCheckedContinuation { continuation in
            coordinator.webView(webView, decidePolicyFor: action) { result in
                policy = result
                continuation.resume()
            }
        }

        #expect(policy == .cancel)
    }

    @Test("initial page load (other type) is allowed")
    func initialLoadAllowed() async {
        let coordinator = makeCoordinator()
        let webView = makeWebView()

        var policy: WKNavigationActionPolicy = .cancel
        let action = MockNavigationAction(type: .other)

        await withCheckedContinuation { continuation in
            coordinator.webView(webView, decidePolicyFor: action) { result in
                policy = result
                continuation.resume()
            }
        }

        #expect(policy == .allow)
    }

    @Test("back/forward navigation is cancelled")
    func backForwardCancelled() async {
        let coordinator = makeCoordinator()
        let webView = makeWebView()

        var policy: WKNavigationActionPolicy = .allow
        let action = MockNavigationAction(type: .backForward)

        await withCheckedContinuation { continuation in
            coordinator.webView(webView, decidePolicyFor: action) { result in
                policy = result
                continuation.resume()
            }
        }

        #expect(policy == .cancel)
    }
}

// MARK: - Helpers

/// Minimal `WKNavigationAction` subclass that exposes a configurable `navigationType`.
private final class MockNavigationAction: WKNavigationAction {
    private let _navigationType: WKNavigationType

    init(type: WKNavigationType) {
        _navigationType = type
        super.init()
    }

    override var navigationType: WKNavigationType { _navigationType }
}
