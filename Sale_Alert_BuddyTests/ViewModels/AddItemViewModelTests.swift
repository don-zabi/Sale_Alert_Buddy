import Testing
import CoreData
import UIKit
@testable import Sale_Alert_Buddy

// MARK: - AddItemViewModel Tests

@Suite("AddItemViewModel")
@MainActor
struct AddItemViewModelTests {

    private func makeCheckService(for html: String) -> PriceCheckService {
        MockURLProtocol.reset()
        MockURLProtocol.stub(urlContaining: "example.com", html: html)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return PriceCheckService(fetcher: HTMLFetcher(session: session))
    }

    // MARK: - Default state

    @Test("urlText starts empty")
    func urlTextStartsEmpty() {
        let vm = AddItemViewModel()
        #expect(vm.urlText == "")
    }

    @Test("memo starts empty")
    func memoStartsEmpty() {
        let vm = AddItemViewModel()
        #expect(vm.memo == "")
    }

    @Test("titleText starts empty")
    func titleTextStartsEmpty() {
        let vm = AddItemViewModel()
        #expect(vm.titleText == "")
    }

    @Test("notification condition defaults are set")
    func notificationConditionDefaults() {
        let vm = AddItemViewModel()
        #expect(vm.notificationConditionType == .percentage)
        #expect(vm.notificationConditionValueText == "1")
    }

    @Test("isRegistering starts false")
    func isRegisteringStartsFalse() {
        let vm = AddItemViewModel()
        #expect(vm.isRegistering == false)
    }

    @Test("errorMessage starts nil")
    func errorMessageStartsNil() {
        let vm = AddItemViewModel()
        #expect(vm.errorMessage == nil)
    }

    @Test("registeredItem starts nil")
    func registeredItemStartsNil() {
        let vm = AddItemViewModel()
        #expect(vm.registeredItem == nil)
    }

    // MARK: - canRegister

    @Test("canRegister is false when urlText is empty")
    func canRegisterFalseWhenEmpty() {
        let vm = AddItemViewModel()
        vm.urlText = ""
        #expect(vm.canRegister == false)
    }

    @Test("canRegister is false when urlText is whitespace only")
    func canRegisterFalseWhenWhitespace() {
        let vm = AddItemViewModel()
        vm.urlText = "   "
        #expect(vm.canRegister == false)
    }

    @Test("canRegister is true when urlText has content and not registering")
    func canRegisterTrueWithURL() {
        let vm = AddItemViewModel()
        vm.urlText = "https://example.com"
        #expect(vm.canRegister == true)
    }

    @Test("canRegister is false when isRegistering is true")
    func canRegisterFalseWhenRegistering() {
        let vm = AddItemViewModel()
        vm.urlText = "https://example.com"
        vm.isRegistering = true
        #expect(vm.canRegister == false)
    }

    @Test("canRegister is false when notification value is invalid")
    func canRegisterFalseWhenNotificationValueInvalid() {
        let vm = AddItemViewModel()
        vm.urlText = "https://example.com"
        vm.notificationConditionValueText = "abc"
        #expect(vm.canRegister == false)
    }

    // MARK: - clearError

    @Test("clearError sets errorMessage to nil")
    func clearError() {
        let vm = AddItemViewModel()
        vm.errorMessage = "some error"
        vm.clearError()
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Plan limit check

    @Test("register sets planLimit error when 20 items already exist")
    @MainActor
    func registerEnforcesPlanLimit() async throws {
        // Use a fresh isolated store so item count is deterministic
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        // Create 20 existing items to hit the free plan limit
        for index in 0..<20 {
            let existing = TrackingItem.create(in: ctx)
            existing.currentUrl = "https://amazon.co.jp/dp/B\(index)"
            existing.domain = "amazon.co.jp"
        }
        store.save(context: ctx)

        let vm = AddItemViewModel()
        vm.urlText = "https://amazon.co.jp/dp/B002"

        await vm.register(context: ctx)

        #expect(vm.errorMessage != nil)
        #expect(vm.isRegistering == false)
        #expect(vm.registeredItem == nil)
        #expect(!(vm.errorMessage ?? "").isEmpty)
    }

    @Test("register does not set isRegistering true when plan limit exceeded")
    @MainActor
    func registerNoNetworkWhenPlanLimitExceeded() async throws {
        // Use a fresh isolated store so item count is deterministic
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        for index in 0..<20 {
            let existing = TrackingItem.create(in: ctx)
            existing.currentUrl = "https://amazon.co.jp/dp/existing-\(index)"
            existing.domain = "amazon.co.jp"
        }
        store.save(context: ctx)

        let vm = AddItemViewModel()
        vm.urlText = "https://amazon.co.jp/dp/new"

        // isRegistering should NOT stay true after returning early
        await vm.register(context: ctx)

        #expect(vm.isRegistering == false)
    }

    @Test("register sets isRegistering during execution then clears it on error")
    @MainActor
    func registerClearsIsRegisteringAfterError() async {
        // Use a fresh isolated store so no plan limit fires
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        let vm = AddItemViewModel()
        vm.urlText = "not-a-valid-url-at-all"

        // With invalid URL and no existing items, registerItem will throw
        await vm.register(context: ctx)

        #expect(vm.isRegistering == false)
    }

    @Test("register prepares review dialog before saving and confirm persists item")
    @MainActor
    func registerShowsReviewBeforeSave() async throws {
        defer { MockURLProtocol.reset() }

        let html = """
        <html>
        <head>
        <title>Example Product</title>
        <meta property="og:image" content="https://example.com/item.jpg">
        <script type="application/ld+json">
        {
          "@context":"https://schema.org",
          "@type":"Product",
          "offers":{"price":"1737","priceCurrency":"JPY"}
        }
        </script>
        </head>
        <body></body>
        </html>
        """

        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext
        let vm = AddItemViewModel(checkService: makeCheckService(for: html))
        vm.urlText = "https://example.com/item"
        vm.memo = "note"

        await vm.register(context: ctx)

        #expect(vm.registeredItem == nil)
        #expect(vm.reviewDialog?.kind == .detected)

        vm.confirmPreparedRegistration(context: ctx)

        #expect(vm.registeredItem != nil)
        #expect(vm.registeredItem?.baselinePriceDecimal == Decimal(1737))
        #expect(vm.registeredItem?.memo == "note")
    }

    // MARK: - Retry flow

    @Test("detected dialog carries preview price for rich card display")
    @MainActor
    func detectedDialogHasPreviewPrice() async throws {
        defer { MockURLProtocol.reset() }

        let html = """
        <html><head><title>プレビュー商品</title>
        <meta property="og:image" content="https://example.com/img.jpg">
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Product","offers":{"price":"3980","priceCurrency":"JPY"}}
        </script></head><body></body></html>
        """
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext
        let vm = AddItemViewModel(checkService: makeCheckService(for: html))
        vm.urlText = "https://example.com/product"

        await vm.register(context: ctx)

        #expect(vm.reviewDialog?.previewPrice != nil)
        #expect(vm.reviewDialog?.previewTitle == "プレビュー商品")
        #expect(vm.reviewDialog?.previewImageURL == "https://example.com/img.jpg")
    }

    @Test("1st detected dialog has isLastAttempt=false (retry available)")
    @MainActor
    func firstAttemptDialogAllowsRetry() async throws {
        defer { MockURLProtocol.reset() }

        let html = """
        <html><head><title>Product</title>
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Product","offers":{"price":"5000","priceCurrency":"JPY"}}
        </script></head><body></body></html>
        """
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext
        let vm = AddItemViewModel(checkService: makeCheckService(for: html))
        vm.urlText = "https://example.com/item"

        await vm.register(context: ctx)

        #expect(vm.reviewDialog?.kind == .detected)
        #expect(vm.reviewDialog?.isLastAttempt == false)
        // 1st attempt must NOT include the live URL (screenshot-only mode)
        #expect(vm.reviewDialog?.previewURL == nil,
                "1st attempt should use screenshot preview, not live WebView")
    }

    @Test("retryInBackground sets isLastAttempt=true on success")
    @MainActor
    func retryInBackgroundSetsLastAttemptOnSuccess() async throws {
        defer { MockURLProtocol.reset() }

        let html = """
        <html><head><title>Product</title>
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Product","offers":{"price":"5000","priceCurrency":"JPY"}}
        </script></head><body></body></html>
        """
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext
        let vm = AddItemViewModel(checkService: makeCheckService(for: html))
        vm.urlText = "https://example.com/item"

        // First attempt
        await vm.register(context: ctx)
        #expect(vm.reviewDialog?.isLastAttempt == false)
        #expect(vm.reviewDialog?.previewURL == nil, "1st attempt: screenshot mode, no live URL")

        // Background retry
        await vm.retryInBackground(context: ctx)

        #expect(vm.reviewDialog?.kind == .detected)
        #expect(vm.reviewDialog?.isLastAttempt == true,
                "Second attempt should mark dialog as last attempt")
        // 2nd attempt MUST supply the live URL for the WebView preview
        #expect(vm.reviewDialog?.previewURL != nil,
                "2nd attempt should use live WebView preview")
    }

    @Test("register() resets previewScreenshot for a fresh attempt")
    @MainActor
    func registerClearsPreviewScreenshot() async {
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext
        let vm = AddItemViewModel()
        // Simulate a screenshot left over from a previous attempt
        vm.previewScreenshot = UIImage()
        vm.urlText = "not-a-valid-url"

        await vm.register(context: ctx)

        #expect(vm.previewScreenshot == nil,
                "register() must clear any stale screenshot before the new attempt")
    }

    @Test("failed dialog always has isLastAttempt=true")
    @MainActor
    func failedDialogIsAlwaysLastAttempt() async {
        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        // An invalid URL triggers invalidURL error (errorMessage, not dialog),
        // so use a URL that will fail fetch with priceNotFound
        MockURLProtocol.reset()
        MockURLProtocol.stub(urlContaining: "noprice.com",
                             html: "<html><body><p>No price here</p></body></html>")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let vm = AddItemViewModel(
            checkService: PriceCheckService(fetcher: HTMLFetcher(session: session))
        )
        vm.urlText = "https://noprice.com/item"

        await vm.register(context: ctx)

        #expect(vm.reviewDialog?.kind == .failed)
        #expect(vm.reviewDialog?.isLastAttempt == true,
                "Failure dialogs should always be last attempt (no more retries)")

        MockURLProtocol.reset()
    }

    // MARK: - Security block on manual capture

    @Test("handleManualCapture returns shouldDismiss=true and sets securityBlockMessage when accessBlocked")
    @MainActor
    func handleManualCaptureSecurityBlock() async {
        defer { MockURLProtocol.reset() }

        // HTML that simulates a Cloudflare challenge page (triggers ProtectionPageDetector)
        let blockedHTML = """
        <html><head><title>Just a moment...</title></head>
        <body>
        <div id="cf-wrapper">
          <div class="cf-browser-verification">Verifying you are human. This may take a few seconds.</div>
          <div class="cf-captcha-container"></div>
        </div>
        </body></html>
        """

        MockURLProtocol.stub(urlContaining: "example.com", html: blockedHTML)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let vm = AddItemViewModel(checkService: PriceCheckService(fetcher: HTMLFetcher(session: session)))
        vm.urlText = "https://example.com/product"

        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        let response = await vm.handleManualCapture(
            html: blockedHTML,
            pageURL: URL(string: "https://example.com/product")!,
            context: ctx
        )

        // After fix: accessBlocked → shouldDismiss=true + securityBlockMessage set
        #expect(response.shouldDismiss == true)
        #expect(vm.securityBlockMessage != nil)
        #expect(!(vm.securityBlockMessage ?? "").isEmpty)
    }

    @Test("handleManualCapture returns shouldDismiss=false when price not found (non-antibot)")
    @MainActor
    func handleManualCaptureNoPrice() async {
        defer { MockURLProtocol.reset() }

        // Normal HTML with no price — priceNotFound, not accessBlocked
        let noPriceHTML = "<html><body><h1>Product</h1><p>No price here</p></body></html>"
        MockURLProtocol.stub(urlContaining: "example.com", html: noPriceHTML)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let vm = AddItemViewModel(checkService: PriceCheckService(fetcher: HTMLFetcher(session: session)))
        vm.urlText = "https://example.com/product"

        let store = PersistenceController(inMemory: true)
        let ctx = store.container.viewContext

        let response = await vm.handleManualCapture(
            html: noPriceHTML,
            pageURL: URL(string: "https://example.com/product")!,
            context: ctx
        )

        // priceNotFound should keep sheet open (show error inline)
        #expect(response.shouldDismiss == false)
        #expect(vm.securityBlockMessage == nil)
    }
}
