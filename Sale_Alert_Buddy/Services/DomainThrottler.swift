import Foundation

/// Actor that enforces per-domain rate limiting and exponential backoff.
///
/// Ensures polite crawling with a minimum 2-second gap between requests to the same
/// domain, and applies exponential backoff for 429 responses. Three consecutive 403
/// responses signal that all items for that domain should be paused.
actor DomainThrottler {

    // MARK: - Shared Instance

    static let shared = DomainThrottler()

    // MARK: - State

    private struct DomainState {
        var lastAccessTime: Date = .distantPast
        var backoffSeconds: TimeInterval = 0
        var consecutive403Count: Int = 0
    }

    private var states: [String: DomainState] = [:]

    // MARK: - Constants

    let minIntervalSeconds: TimeInterval = 2.0
    let maxBackoffSeconds: TimeInterval = 86400  // 24 hours

    // MARK: - Public API

    /// Waits if necessary before a request to `domain` can proceed.
    ///
    /// Claims the slot by advancing `lastAccessTime` before sleeping so that concurrent
    /// callers for the same domain compute a fresh delay rather than racing through the
    /// same window. Propagates `CancellationError` so that a cancelled `checkAll` exits
    /// throttle waits promptly.
    func waitIfNeeded(for domain: String) async throws {
        var state = states[domain] ?? DomainState()
        let totalInterval = minIntervalSeconds + state.backoffSeconds
        let elapsed = Date().timeIntervalSince(state.lastAccessTime)
        let remaining = totalInterval - elapsed

        if remaining > 0 {
            // Claim the slot before sleeping so concurrent callers see an updated time.
            state.lastAccessTime = Date().addingTimeInterval(remaining)
            states[domain] = state
            try await Task.sleep(for: .seconds(remaining))
        }
    }

    /// Records a successful fetch for `domain`, resetting backoff and error counts.
    func recordSuccess(for domain: String) {
        var state = states[domain] ?? DomainState()
        state.backoffSeconds = 0
        state.consecutive403Count = 0
        state.lastAccessTime = Date()
        states[domain] = state
    }

    /// Records a failed fetch for `domain`.
    ///
    /// - Parameter httpStatus: The HTTP status code of the response, if available.
    /// - Returns: `true` if three consecutive 403s have been seen and all items for
    ///   this domain should be fully paused; `false` otherwise.
    @discardableResult
    func recordFailure(for domain: String, httpStatus: Int?) -> Bool {
        var state = states[domain] ?? DomainState()
        defer { states[domain] = state }

        state.lastAccessTime = Date()

        switch httpStatus {
        case 429:
            // Exponential backoff: start at 5s, double each time, cap at max
            if state.backoffSeconds < 5 {
                state.backoffSeconds = 5
            } else {
                state.backoffSeconds = min(state.backoffSeconds * 2, maxBackoffSeconds)
            }
            return false

        case 403:
            state.consecutive403Count += 1
            if state.consecutive403Count >= 3 {
                return true
            }
            return false

        default:
            return false
        }
    }

    /// Returns the current backoff duration for `domain` (0 if no backoff set).
    func backoffSeconds(for domain: String) -> TimeInterval {
        states[domain]?.backoffSeconds ?? 0
    }

    /// Resets all throttle state for `domain`.
    func reset(for domain: String) {
        states.removeValue(forKey: domain)
    }
}
