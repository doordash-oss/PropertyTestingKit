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

    @Test("measureSanCoverage detects code execution")
    func testMeasureSanCoverage() {
        let db = MockDatabase()

        guard let diff = measureSanCoverage({
            db.write(key: "test", value: "value")
        }) else {
            Issue.record("SanCov counters not available")
            return
        }

        #expect(diff.hasChanges)
        print("Executed \(diff.newlyCoveredCount) new edges, \(diff.changedCount) changed")
    }

    @Test("measureSanCoverage shows different code paths")
    func testDifferentCodePaths() {
        let db = MockDatabase()

        // Measure write path
        let writeDiff = measureSanCoverage {
            db.write(key: "a", value: "1")
        }

        // Measure read path
        let readDiff = measureSanCoverage {
            _ = db.read(key: "a")
        }

        guard let w = writeDiff, let r = readDiff else {
            Issue.record("SanCov counters not available")
            return
        }

        // Both should have changes
        #expect(w.hasChanges)
        #expect(r.hasChanges)

        // They might hit different edges
        print("Write path: \(w.newlyCoveredCount) edges")
        print("Read path: \(r.newlyCoveredCount) edges")
    }

    @Test("measureSanCoverage isolates measurements between calls")
    func testIsolatedCoverage() {
        let db = MockDatabase()

        // First call exercises some code
        _ = measureSanCoverage {
            db.write(key: "warmup", value: "data")
        }

        // Second measurement should only see new executions (difference-based)
        var result: String?
        let diff = measureSanCoverage {
            db.write(key: "test", value: "value")
            result = db.read(key: "test")
        }

        #expect(result == "value")

        if let diff = diff {
            // Should see coverage from both write and read
            print("Isolated coverage: \(diff.newlyCoveredCount) new edges")
        }
    }

    @Test("async measureSanCoverage captures code execution")
    func testAsyncMeasureSanCoverage() async {
        guard let diff = await measureSanCoverage({
            // Simulate async work
            try? await Task.sleep(nanoseconds: 1_000)
            _ = [1, 2, 3].reduce(0, +)
        }) else {
            Issue.record("SanCov counters not available")
            return
        }

        #expect(diff.hasChanges, "Async code should produce coverage changes")
        print("Async coverage: \(diff.newlyCoveredCount) new edges, \(diff.changedCount) changed")
    }

    @Test("measureSanCovSourceCoverage captures function names")
    func testSourceCoverage() {
        let db = MockDatabase()

        guard let coverage = measureSanCovSourceCoverage({
            db.write(key: "test", value: "value")
            _ = db.read(key: "test")
        }) else {
            Issue.record("SanCov counters not available")
            return
        }

        #expect(coverage.coveredCount > 0, "Should have covered edges")

        // Check we got function names
        let hasWriteFunction = coverage.coveredFunctions.contains { $0.contains("write") }
        let hasReadFunction = coverage.coveredFunctions.contains { $0.contains("read") }

        #expect(hasWriteFunction || hasReadFunction, "Should have covered database functions")
        print("Covered \(coverage.coveredFunctions.count) functions")
    }
}

// MARK: - SanCovCounters Struct Tests

@Suite("SanCovCounters Struct")
struct SanCovCountersStructTests {

    @Test("SanCovDiff correctly identifies newly covered indices")
    func testSanCovDiff() {
        let before = SanCovCounters(counters: [0, 1, 0, 1, 0] as [UInt8])
        let after = SanCovCounters(counters: [1, 1, 1, 1, 0] as [UInt8])

        let diff = after.difference(from: before)

        // Indices 0 and 2 went from 0 to 1 (newly covered)
        #expect(diff.newlyCoveredIndices.contains(0))
        #expect(diff.newlyCoveredIndices.contains(2))
        #expect(!diff.newlyCoveredIndices.contains(1), "Index 1 was already covered")
        #expect(!diff.newlyCoveredIndices.contains(3), "Index 3 was already covered")
        #expect(!diff.newlyCoveredIndices.contains(4), "Index 4 is still not covered")
    }

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
