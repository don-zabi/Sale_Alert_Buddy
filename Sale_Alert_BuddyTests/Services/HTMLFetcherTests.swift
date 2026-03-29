import Testing
import Foundation
@testable import Sale_Alert_Buddy

struct HTMLFetcherTests {

    @Test func fetchSendsBrowserLikeJapaneseHeaders() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(urlContaining: "example.com", html: "<html><body>ok</body></html>")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fetcher = HTMLFetcher(session: session)

        _ = try await fetcher.fetch(url: URL(string: "https://example.com/product")!)

        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "User-Agent") == HTMLFetcher.mobileUserAgent)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept") == HTMLFetcher.defaultHeaders["Accept"])
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept-Language") == HTMLFetcher.defaultHeaders["Accept-Language"])
    }
}
