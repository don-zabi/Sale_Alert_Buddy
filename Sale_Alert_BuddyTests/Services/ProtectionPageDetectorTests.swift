import Testing
import Foundation
import CoreData
@testable import Sale_Alert_Buddy

@Suite("ProtectionPageDetector")
@MainActor
struct ProtectionPageDetectorTests {

    @Test func detectsCloudflareChallengePage() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Just a moment...</title></head>
        <body>
        <script>window._cf_chl_opt = { cZone: 'www.yslb.jp' };</script>
        </body>
        </html>
        """

        let result = ProtectionPageDetector.isProtectionPage(
            html,
            url: URL(string: "https://www.yslb.jp/product/WW-51533YSL.html")!
        )

        #expect(result)
    }

    @Test func detectsTemuChallengePage() {
        let html = """
        <html><body>
        <script src="https://static.kwcdn.com/upload-static/assets/chl/js/challenge.js"></script>
        </body></html>
        """

        let result = ProtectionPageDetector.isProtectionPage(
            html,
            url: URL(string: "https://temu.com/jp/channel/lightning-deals.html")!
        )

        #expect(result)
    }

    @Test func registerItemThrowsAccessBlockedForProtectionPage() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Just a moment...</title></head>
        <body>
        <script>window._cf_chl_opt = { cZone: 'www.yslb.jp' };</script>
        </body>
        </html>
        """

        MockURLProtocol.stub(
            urlContaining: "yslb.jp",
            html: html
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let service = PriceCheckService(
            fetcher: HTMLFetcher(session: session),
            pipeline: PriceExtractionPipeline(),
            sitePriceResolver: SiteSpecificPriceResolver(session: session),
            metadataExtractor: MetadataExtractor(),
            throttler: DomainThrottler(),
            notificationService: NotificationService.shared
        )
        let context = TestPersistence.newContext()

        do {
            _ = try await service.registerItem(
                urlString: "https://www.yslb.jp/makeup/makeup-lips/makeup-lipstick/ysl-lovenude-lip-blusher/WW-51533YSL.html",
                memo: nil,
                tags: [],
                context: context
            )
            #expect(Bool(false), "Expected accessBlocked error")
        } catch let error as PriceCheckError {
            switch error {
            case .accessBlocked:
                break
            default:
                #expect(Bool(false), "Expected accessBlocked but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected PriceCheckError.accessBlocked but got \(error)")
        }
    }
}
