import Foundation

/// Fetches the HTML content of a URL using a mobile Safari user-agent.
///
/// Designed to be polite: one connection per host, with configurable timeout.
/// Dependency-injected URLSession enables unit testing without real network calls.
actor HTMLFetcher {

    struct FetchResult {
        let html: String
        let httpStatus: Int
        let finalURL: URL
        let durationMs: Int32
    }

    private let session: URLSession

    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/17.0 Mobile/15E148 Safari/604.1"

    /// - Parameter session: URLSession to use. Defaults to a session with redirect guard.
    ///   Pass a custom session in tests to inject mock URLProtocols.
    init(session: URLSession = HTMLFetcher.makeDefaultSession()) {
        self.session = session
    }

    /// Creates a URLSession configured with polite defaults for production use.
    ///
    /// The session uses a `RedirectGuard` delegate that:
    /// - Blocks HTTPS → HTTP scheme downgrades.
    /// - Caps redirect chains at `maxRedirects` (default 5).
    static func makeDefaultSession(timeout: TimeInterval = 15, maxRedirects: Int = 5) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = ["User-Agent": mobileUserAgent]
        let delegate = RedirectGuard(maxRedirects: maxRedirects)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Fetches the HTML at `url`, measuring duration with `ContinuousClock`.
    ///
    /// - Parameters:
    ///   - url: The URL to fetch.
    ///   - timeout: Request timeout in seconds. Applies to the URLSession configuration
    ///     only when a fresh session is created; ignored when a custom session was injected.
    /// - Throws: `HTMLFetchError` on any failure.
    /// - Returns: A `FetchResult` with html, HTTP status, final URL (after redirects), and duration.
    func fetch(url: URL, timeout: TimeInterval = 15) async throws -> FetchResult {
        var request = URLRequest(url: url)
        request.setValue(HTMLFetcher.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        let clock = ContinuousClock()
        let startInstant = clock.now

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw HTMLFetchError.network(underlying: urlError)
        } catch {
            // Wrap unexpected errors in a generic URLError so HTMLFetchError stays Sendable
            throw HTMLFetchError.network(underlying: URLError(.unknown))
        }

        let elapsed = clock.now - startInstant
        let durationMs = Int32(elapsed.components.seconds * 1_000 +
                               elapsed.components.attoseconds / 1_000_000_000_000_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTMLFetchError.network(underlying: URLError(.badServerResponse))
        }

        let statusCode = httpResponse.statusCode

        // Check for non-2xx HTTP status before MIME type check
        if statusCode >= 400 && statusCode < 500 {
            throw HTMLFetchError.http4xx(statusCode: statusCode)
        }
        if statusCode >= 500 {
            throw HTMLFetchError.http5xx(statusCode: statusCode)
        }

        // Verify MIME type is text/*
        if let mimeType = httpResponse.mimeType, !mimeType.hasPrefix("text/") {
            throw HTMLFetchError.notHTML
        }

        // Determine encoding from Content-Type header, fall back to UTF-8
        let html = decodeData(data, response: httpResponse)

        let finalURL = httpResponse.url ?? url

        return FetchResult(
            html: html,
            httpStatus: statusCode,
            finalURL: finalURL,
            durationMs: durationMs
        )
    }

    // MARK: - Private Helpers

    private func decodeData(_ data: Data, response: HTTPURLResponse) -> String {
        // Try to extract charset from Content-Type header
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           let charset = extractCharset(from: contentType),
           let encoding = stringEncoding(from: charset),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        // Fall back to UTF-8
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        // Last resort: lossy ASCII
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private func extractCharset(from contentType: String) -> String? {
        // Content-Type: text/html; charset=UTF-8
        let parts = contentType.lowercased().components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("charset=") {
                let charset = String(trimmed.dropFirst("charset=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return charset
            }
        }
        return nil
    }

    private func stringEncoding(from charset: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }
}

// MARK: - RedirectGuard

/// URLSession delegate that enforces redirect safety:
/// - Blocks HTTPS → HTTP scheme downgrades.
/// - Caps redirect chains at `maxRedirects` per task.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var redirectCounts: [URLSessionTask: Int] = [:]
    private let maxRedirects: Int

    init(maxRedirects: Int) {
        self.maxRedirects = maxRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Block HTTPS → HTTP scheme downgrade
        if let fromScheme = response.url?.scheme?.lowercased(),
           let toScheme = request.url?.scheme?.lowercased(),
           fromScheme == "https" && toScheme == "http" {
            completionHandler(nil)
            return
        }

        // Enforce redirect cap
        lock.lock()
        let count = (redirectCounts[task] ?? 0) + 1
        redirectCounts[task] = count
        lock.unlock()

        completionHandler(count <= maxRedirects ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        redirectCounts.removeValue(forKey: task)
        lock.unlock()
    }
}
