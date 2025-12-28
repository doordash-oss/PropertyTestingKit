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

        guard let snapshot = SanCovCounters.snapshot() else {
            Issue.record("Failed to get SanCov snapshot")
            return
        }

        #expect(snapshot.count > 0)
        print("Captured \(snapshot.count) counters")
    }

    @Test("Measurement context provides isolated coverage")
    func testMeasurementContext() {
        guard SanCovCounters.isAvailable else {
            Issue.record("SanCov counters not available")
            return
        }

        guard let context = SanCovCounters.beginMeasurement() else {
            Issue.record("Failed to begin measurement")
            return
        }
        defer { SanCovCounters.endMeasurement(context) }

        // Do some work
        var sum = 0
        for i in 0..<100 { sum += i }
        _ = sum

        // Get coverage from this context
        let coverage = SanCovCounters.snapshotCoveredArrays(with: context)
        #expect(coverage != nil, "Should get coverage from context")
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
