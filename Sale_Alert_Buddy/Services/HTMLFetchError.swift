import Foundation

/// Errors thrown by HTMLFetcher during page retrieval.
///
/// `URLError` is `Sendable`; using it (instead of `Error`) allows `HTMLFetchError`
/// to satisfy `Sendable` without `@unchecked`.
enum HTMLFetchError: Error, Sendable {
    case invalidURL
    /// A transport-level failure (DNS, timeout, no connection, etc.).
    case network(underlying: URLError)
    case http4xx(statusCode: Int)
    case http5xx(statusCode: Int)
    case notHTML

    /// Maps this error to the FetchErrorType enum used in CoreData logs.
    var fetchErrorType: FetchErrorType {
        switch self {
        case .invalidURL:
            return .network
        case .network:
            return .network
        case .http4xx:
            return .http4xx
        case .http5xx:
            return .http5xx
        case .notHTML:
            return .extractionFailed
        }
    }

    /// The HTTP status code, if available from an HTTP error response.
    var httpStatusCode: Int? {
        switch self {
        case .http4xx(let code): return code
        case .http5xx(let code): return code
        default: return nil
        }
    }
}
