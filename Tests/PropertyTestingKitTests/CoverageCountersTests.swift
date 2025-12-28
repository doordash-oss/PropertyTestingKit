import Testing
@testable import PropertyTestingKit

// MARK: - SanCov Coverage Tests (Task-Isolated)

@Suite("SanCov Coverage API")
struct SanCovCoverageTests {

    @Test("SanCovCounters.snapshot captures counter state")
    func testSnapshot() {
        guard SanCovCounters.isAvailable else {
            Issue.record("SanCov counters not available (expected when not built with -sanitize-coverage)")
            return
        }

        SanCovCounters.reset()
        guard let snapshot = SanCovCounters.snapshot() else {
            Issue.record("Failed to get SanCov snapshot")
            return
        }

        #expect(snapshot.count > 0)
        print("Captured \(snapshot.count) counters")
    }
}

// MARK: - SanCovCounters Struct Tests

@Suite("SanCovCounters Struct")
struct SanCovCountersStructTests {

    @Test("SanCovCounters.coveredIndices returns correct set")
    func testCoveredIndices() {
        let counters = SanCovCounters(counters: [0, 1, 0, 1, 1, 0] as [UInt8])

        let covered = counters.coveredIndices
        #expect(covered == Set([1, 3, 4]))
    }

    @Test("SanCovCounters.coveredCount returns correct count")
    func testCoveredCount() {
        let counters = SanCovCounters(counters: [0, 1, 0, 1, 1, 0] as [UInt8])
        #expect(counters.coveredCount == 3)
    }
}
