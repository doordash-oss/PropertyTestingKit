import Testing
@testable import PropertyTestingKit

// MARK: - SanCov Coverage Tests (Task-Isolated)

@Suite("SanCov Coverage API")
struct SanCovCoverageTests {

    @Test("Measurement context provides isolated coverage")
    func testMeasurementContext() throws {
        guard SanCovCounters.isAvailable else {
            Issue.record("SanCov counters not available")
            return
        }

        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        // Do some work
        var sum = 0
        for i in 0..<100 { sum += i }
        _ = sum

        // Get coverage from this context
        let coverage = try SanCovCounters.snapshotCoveredArrays(with: context)
        #expect(coverage.count > 0, "Should get coverage from context")
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
