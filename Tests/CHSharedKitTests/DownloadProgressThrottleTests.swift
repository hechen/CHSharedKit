import Foundation
import Testing
@testable import CHLocalLLM

/// 2.19.8 hopped to the main actor once per `didWriteData` callback, which
/// froze the model picker and grew memory during a download. The throttle
/// bounds those hops without losing the final count.
@Suite("Download progress throttle")
struct DownloadProgressThrottleTests {
    @Test("A burst of callbacks inside one interval admits only the first")
    func burstIsCoalesced() {
        let throttle = DownloadProgressThrottle(interval: 0.1)
        let start: UInt64 = 1_000_000_000
        let admitted = (0..<1_000).filter { i in
            throttle.admit(isFinal: false, now: start + UInt64(i) * 50_000) // 1,000 calls in 50 ms
        }
        #expect(admitted.count == 1)
    }

    @Test("Callbacks spread over a second pass about ten times")
    func steadyRateIsBounded() {
        let throttle = DownloadProgressThrottle(interval: 0.1)
        let start: UInt64 = 1_000_000_000
        let admitted = (0..<2_000).filter { i in
            throttle.admit(isFinal: false, now: start + UInt64(i) * 500_000) // every 0.5 ms for 1 s
        }
        #expect((10...11).contains(admitted.count))
    }

    @Test("The final count always passes, even straight after another update")
    func finalAlwaysPasses() {
        let throttle = DownloadProgressThrottle(interval: 0.1)
        let now: UInt64 = 5_000_000_000
        #expect(throttle.admit(isFinal: false, now: now))
        #expect(!throttle.admit(isFinal: false, now: now + 1))
        #expect(throttle.admit(isFinal: true, now: now + 2))
    }
}
