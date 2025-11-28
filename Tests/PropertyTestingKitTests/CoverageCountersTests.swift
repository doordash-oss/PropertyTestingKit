import Testing
import PropertyTestingKit

// MARK: - CoverageCounters Tests (In-Memory, No File I/O)

@Suite("CoverageCounters API", .serialized)
struct CoverageCountersTests {

    @Test("CoverageCounters.snapshot captures counter state")
    func testSnapshot() {
        guard let snapshot = CoverageCounters.snapshot() else {
            Issue.record("Coverage counters not available (expected when not built with coverage)")
            return
        }

        #expect(snapshot.count > 0)
        print("Captured \(snapshot.count) counters")
    }

    @Test("measureCoverage detects code execution")
    func testMeasureCoverage() {
        let db = MockDatabase()

        guard let diff = measureCoverage({
            db.write(key: "test", value: "value")
        }) else {
            Issue.record("Coverage counters not available")
            return
        }

        #expect(diff.hasChanges)
        print("Executed \(diff.executedRegions) new regions, \(diff.changedCount) changed")
    }

    @Test("measureCoverage shows different code paths")
    func testDifferentCodePaths() {
        let db = MockDatabase()

        // Measure write path
        let writeDiff = measureCoverage {
            db.write(key: "a", value: "1")
        }

        // Measure read path
        let readDiff = measureCoverage {
            _ = db.read(key: "a")
        }

        guard let w = writeDiff, let r = readDiff else {
            Issue.record("Coverage counters not available")
            return
        }

        // Both should have changes
        #expect(w.hasChanges)
        #expect(r.hasChanges)

        // They might hit different regions
        print("Write path: \(w.executedRegions) regions")
        print("Read path: \(r.executedRegions) regions")
    }

    @Test("measureCoverage isolates measurements between calls")
    func testIsolatedCoverage() {
        let db = MockDatabase()

        // First call exercises some code
        _ = measureCoverage {
            db.write(key: "warmup", value: "data")
        }

        // Second measurement should only see new executions (difference-based)
        var result: String?
        let diff = measureCoverage {
            db.write(key: "test", value: "value")
            result = db.read(key: "test")
        }

        #expect(result == "value")

        if let diff = diff {
            // Should see fewer "newly executed" regions since write was already called
            print("Isolated coverage: \(diff.executedRegions) regions")
        }
    }
}
