import Testing
import Foundation
@testable import Sale_Alert_Buddy

/// Unit tests for DomainThrottler backoff, 403 handling, and reset behavior.
///
/// Each test uses a fresh DomainThrottler() instance to avoid shared state.
/// All tests are async because DomainThrottler is an actor.
struct DomainThrottlerTests {

    // MARK: - Constants

    @Test func minIntervalIs2Seconds() async {
        let throttler = DomainThrottler()
        let min = await throttler.minIntervalSeconds
        #expect(min == 2.0)
    }

    @Test func maxBackoffIs86400Seconds() async {
        let throttler = DomainThrottler()
        let max = await throttler.maxBackoffSeconds
        #expect(max == 86400)
    }

    // MARK: - Initial State

    @Test func unknownDomainHasZeroBackoff() async {
        let throttler = DomainThrottler()
        let backoff = await throttler.backoffSeconds(for: "new-domain.com")
        #expect(backoff == 0)
    }

    // MARK: - 429 Exponential Backoff

    @Test func firstRecordFailure429SetsBackoffTo5() async {
        let throttler = DomainThrottler()
        let domain = "example.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 429)

        let backoff = await throttler.backoffSeconds(for: domain)
        #expect(backoff == 5)
    }

    @Test func secondRecordFailure429DoublesBackoffTo10() async {
        let throttler = DomainThrottler()
        let domain = "example.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 429)
        _ = await throttler.recordFailure(for: domain, httpStatus: 429)

        let backoff = await throttler.backoffSeconds(for: domain)
        #expect(backoff == 10)
    }

    @Test func thirdRecordFailure429DoublesBackoffTo20() async {
        let throttler = DomainThrottler()
        let domain = "example.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 429)
        _ = await throttler.recordFailure(for: domain, httpStatus: 429)
        _ = await throttler.recordFailure(for: domain, httpStatus: 429)

        let backoff = await throttler.backoffSeconds(for: domain)
        #expect(backoff == 20)
    }

    @Test func backoffSequenceDoubles5_10_20_40() async {
        let throttler = DomainThrottler()
        let domain = "example.com"
        let expected: [TimeInterval] = [5, 10, 20, 40]

        for (index, expectedValue) in expected.enumerated() {
            _ = await throttler.recordFailure(for: domain, httpStatus: 429)
            let backoff = await throttler.backoffSeconds(for: domain)
            #expect(backoff == expectedValue, "At index \(index): expected \(expectedValue), got \(backoff)")
        }
    }

    @Test func backoffCappedAtMaxBackoff86400() async {
        let throttler = DomainThrottler()
        let domain = "example.com"
        let maxBackoff = await throttler.maxBackoffSeconds

        // Apply many 429s — enough to exceed 86400 without cap
        for _ in 0..<30 {
            _ = await throttler.recordFailure(for: domain, httpStatus: 429)
        }

        let backoff = await throttler.backoffSeconds(for: domain)
        #expect(backoff == maxBackoff)
        #expect(backoff <= maxBackoff)
    }

    // MARK: - recordSuccess Resets Backoff

    @Test func recordSuccessResetsBackoffToZero() async {
        let throttler = DomainThrottler()
        let domain = "example.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 429)
        _ = await throttler.recordFailure(for: domain, httpStatus: 429)

        let backoffBefore = await throttler.backoffSeconds(for: domain)
        #expect(backoffBefore == 10)

        await throttler.recordSuccess(for: domain)

        let backoffAfter = await throttler.backoffSeconds(for: domain)
        #expect(backoffAfter == 0)
    }

    @Test func recordSuccessOnFreshDomainIsNoOp() async {
        let throttler = DomainThrottler()
        await throttler.recordSuccess(for: "fresh.com")
        #expect(await throttler.backoffSeconds(for: "fresh.com") == 0)
    }

    // MARK: - 403 Consecutive Count

    @Test func single403ReturnsFalse() async {
        let throttler = DomainThrottler()
        let shouldPause = await throttler.recordFailure(for: "site.com", httpStatus: 403)
        #expect(shouldPause == false)
    }

    @Test func two403sReturnFalse() async {
        let throttler = DomainThrottler()
        let domain = "site.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        let shouldPause = await throttler.recordFailure(for: domain, httpStatus: 403)
        #expect(shouldPause == false)
    }

    @Test func three403sReturnTrue() async {
        let throttler = DomainThrottler()
        let domain = "site.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        let shouldPause = await throttler.recordFailure(for: domain, httpStatus: 403)
        #expect(shouldPause == true)
    }

    @Test func fourth403AfterThreeAlsoReturnsTrueCountNotReset() async {
        let throttler = DomainThrottler()
        let domain = "site.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)

        // 4th 403 — count is now 4, still >= 3
        let shouldPause = await throttler.recordFailure(for: domain, httpStatus: 403)
        #expect(shouldPause == true)
    }

    // MARK: - recordSuccess Resets 403 Counter

    @Test func recordSuccessResets403CounterAndFreshThree403sTriggerPauseAgain() async {
        let throttler = DomainThrottler()
        let domain = "site.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        await throttler.recordSuccess(for: domain)

        // Counter reset — need 3 fresh 403s
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        let shouldPause = await throttler.recordFailure(for: domain, httpStatus: 403)
        #expect(shouldPause == true)
    }

    @Test func afterSuccessResetOneSingle403DoesNotTriggerPause() async {
        let throttler = DomainThrottler()
        let domain = "site.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        await throttler.recordSuccess(for: domain)

        // Only one 403 after reset — should NOT pause
        let shouldPause = await throttler.recordFailure(for: domain, httpStatus: 403)
        #expect(shouldPause == false)
    }

    // MARK: - Non-4xx / Other Status Codes

    @Test func status503DoesNotAffectBackoff() async {
        let throttler = DomainThrottler()
        let domain = "example.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 503)
        _ = await throttler.recordFailure(for: domain, httpStatus: 500)

        let backoff = await throttler.backoffSeconds(for: domain)
        #expect(backoff == 0)
    }

    @Test func status500ReturnsFalse() async {
        let throttler = DomainThrottler()
        let shouldPause = await throttler.recordFailure(for: "example.com", httpStatus: 500)
        #expect(shouldPause == false)
    }

    @Test func nilStatusReturnsFalse() async {
        let throttler = DomainThrottler()
        let shouldPause = await throttler.recordFailure(for: "example.com", httpStatus: nil)
        #expect(shouldPause == false)
    }

    @Test func nilStatusDoesNotAffectBackoff() async {
        let throttler = DomainThrottler()
        let domain = "example.com"
        _ = await throttler.recordFailure(for: domain, httpStatus: nil)
        #expect(await throttler.backoffSeconds(for: domain) == 0)
    }

    // MARK: - reset()

    @Test func resetClearsBackoffState() async {
        let throttler = DomainThrottler()
        let domain = "example.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 429)
        _ = await throttler.recordFailure(for: domain, httpStatus: 429)

        await throttler.reset(for: domain)

        #expect(await throttler.backoffSeconds(for: domain) == 0)
    }

    @Test func resetClears403Counter() async {
        let throttler = DomainThrottler()
        let domain = "example.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)

        await throttler.reset(for: domain)

        // After reset, the next single 403 should return false
        let shouldPause = await throttler.recordFailure(for: domain, httpStatus: 403)
        #expect(shouldPause == false)
    }

    @Test func resetUnknownDomainIsNoOp() async {
        let throttler = DomainThrottler()
        await throttler.reset(for: "never-seen.com")
        #expect(await throttler.backoffSeconds(for: "never-seen.com") == 0)
    }

    @Test func afterResetNewThree403sTriggerPause() async {
        let throttler = DomainThrottler()
        let domain = "example.com"

        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)

        await throttler.reset(for: domain)

        // Post-reset: three fresh 403s
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        _ = await throttler.recordFailure(for: domain, httpStatus: 403)
        let shouldPause = await throttler.recordFailure(for: domain, httpStatus: 403)
        #expect(shouldPause == true)
    }

    // MARK: - Domain Isolation

    @Test func differentDomainsTrackedIndependently() async {
        let throttler = DomainThrottler()
        let domainA = "site-a.com"
        let domainB = "site-b.com"

        _ = await throttler.recordFailure(for: domainA, httpStatus: 429)
        _ = await throttler.recordFailure(for: domainA, httpStatus: 429)

        let backoffA = await throttler.backoffSeconds(for: domainA)
        let backoffB = await throttler.backoffSeconds(for: domainB)

        #expect(backoffA == 10)
        #expect(backoffB == 0)
    }

    @Test func successOnOneDomainDoesNotAffectAnother() async {
        let throttler = DomainThrottler()
        let domainA = "site-a.com"
        let domainB = "site-b.com"

        _ = await throttler.recordFailure(for: domainA, httpStatus: 429)
        _ = await throttler.recordFailure(for: domainB, httpStatus: 429)

        await throttler.recordSuccess(for: domainA)

        #expect(await throttler.backoffSeconds(for: domainA) == 0)
        #expect(await throttler.backoffSeconds(for: domainB) == 5)
    }
}
