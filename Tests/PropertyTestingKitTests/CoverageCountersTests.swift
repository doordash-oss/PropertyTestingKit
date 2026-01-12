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
