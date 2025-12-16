import Testing
@testable import PropertyTestingKit

// MARK: - CoverageCounters Tests (In-Memory, No File I/O)

@Suite("CoverageCounters API")
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

    @Test("CounterDiff.delta returns correct delta for specific index")
    func testDeltaAtIndex() {
        guard let diff = measureCoverage({
            // Execute some code to create a diff
            _ = [1, 2, 3].map { $0 * 2 }
        }) else {
            Issue.record("Coverage counters not available")
            return
        }

        // Test delta for changed indices
        for index in diff.changedIndices.prefix(3) {
            let delta = diff.delta(at: index)
            // Delta should be non-zero for changed indices
            #expect(delta != 0, "Delta at changed index \(index) should be non-zero")
        }

        // Test delta for an index that didn't change (if any exist)
        if diff.changedIndices.count < diff.after.count {
            // Find an index that didn't change
            let unchangedIndex = (0..<diff.after.count).first { !diff.changedIndices.contains($0) }
            if let idx = unchangedIndex {
                let delta = diff.delta(at: idx)
                #expect(delta == 0, "Delta at unchanged index should be zero")
            }
        }
    }

    @Test("async measureCoverage captures code execution")
    func testAsyncMeasureCoverage() async {
        guard let diff = await measureCoverage({
            // Simulate async work
            try? await Task.sleep(nanoseconds: 1_000)
            _ = [1, 2, 3].reduce(0, +)
        }) else {
            Issue.record("Coverage counters not available")
            return
        }

        #expect(diff.hasChanges, "Async code should produce coverage changes")
        print("Async coverage: \(diff.executedRegions) regions, \(diff.changedCount) changed")
    }

    // MARK: - Branch Coverage Tests

    @Test("difference handles counters with different sizes - before larger")
    func testDifferenceWithLargerBefore() {
        // Create counters where 'before' has more elements than 'after'
        let before = CoverageCounters(counters: [1, 2, 3, 4, 5])
        let after = CoverageCounters(counters: [1, 2, 3])

        let diff = after.difference(from: before)

        // Should handle the size difference - indices 3,4 should show as changed
        #expect(diff.changedIndices.contains(3), "Index 3 should be changed (4 -> 0)")
        #expect(diff.changedIndices.contains(4), "Index 4 should be changed (5 -> 0)")
    }

    @Test("difference handles counters with different sizes - after larger")
    func testDifferenceWithLargerAfter() {
        // Create counters where 'after' has more elements than 'before'
        let before = CoverageCounters(counters: [1, 2, 3])
        let after = CoverageCounters(counters: [1, 2, 3, 4, 5])

        let diff = after.difference(from: before)

        // Should handle the size difference - indices 3,4 should show as newly executed
        #expect(diff.changedIndices.contains(3), "Index 3 should be changed (0 -> 4)")
        #expect(diff.changedIndices.contains(4), "Index 4 should be changed (0 -> 5)")
        #expect(diff.newlyExecutedIndices.contains(3), "Index 3 should be newly executed")
        #expect(diff.newlyExecutedIndices.contains(4), "Index 4 should be newly executed")
    }

    @Test("delta handles out-of-bounds index for before counters")
    func testDeltaOutOfBoundsBefore() {
        let before = CoverageCounters(counters: [1, 2])
        let after = CoverageCounters(counters: [1, 2, 3, 4])

        let diff = after.difference(from: before)

        // Index 2 is out of bounds for 'before' but valid for 'after'
        let delta = diff.delta(at: 2)
        #expect(delta == 3, "Delta should be 3 (0 -> 3)")

        // Index 3 is also out of bounds for 'before'
        let delta3 = diff.delta(at: 3)
        #expect(delta3 == 4, "Delta should be 4 (0 -> 4)")
    }

    @Test("delta handles out-of-bounds index for after counters")
    func testDeltaOutOfBoundsAfter() {
        let before = CoverageCounters(counters: [1, 2, 3, 4])
        let after = CoverageCounters(counters: [1, 2])

        let diff = after.difference(from: before)

        // Index 2 is out of bounds for 'after' but valid for 'before'
        let delta = diff.delta(at: 2)
        #expect(delta == -3, "Delta should be -3 (3 -> 0)")

        // Index 3 is also out of bounds for 'after'
        let delta3 = diff.delta(at: 3)
        #expect(delta3 == -4, "Delta should be -4 (4 -> 0)")
    }

    @Test("delta handles out-of-bounds index for both counters")
    func testDeltaOutOfBoundsBoth() {
        let before = CoverageCounters(counters: [1, 2])
        let after = CoverageCounters(counters: [1, 2])

        let diff = after.difference(from: before)

        // Index 10 is out of bounds for both
        let delta = diff.delta(at: 10)
        #expect(delta == 0, "Delta should be 0 when index is out of bounds for both")
    }

    // MARK: - Snapshot Guard Tests

    @Test("snapshot returns nil when coverage is not available")
    func testSnapshotNotAvailable() {
        let result = CoverageCounters.snapshot(
            isAvailable: false,
            beginCounters: { nil },
            endCounters: { nil }
        )
        #expect(result == nil)
    }

    @Test("snapshot returns nil when begin pointer is nil")
    func testSnapshotNilBegin() {
        let result = CoverageCounters.snapshot(
            isAvailable: true,
            beginCounters: { nil },
            endCounters: { UnsafeMutablePointer<UInt64>.allocate(capacity: 1) }
        )
        #expect(result == nil)
    }

    @Test("snapshot returns nil when end pointer is nil")
    func testSnapshotNilEnd() {
        let result = CoverageCounters.snapshot(
            isAvailable: true,
            beginCounters: { UnsafeMutablePointer<UInt64>.allocate(capacity: 1) },
            endCounters: { nil }
        )
        #expect(result == nil)
    }

    @Test("snapshot returns nil when count is zero or negative")
    func testSnapshotZeroCount() {
        // Create a pointer where end == begin (count = 0)
        let ptr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { ptr.deallocate() }

        let result = CoverageCounters.snapshot(
            isAvailable: true,
            beginCounters: { ptr },
            endCounters: { ptr }  // Same as begin, so count = 0
        )
        #expect(result == nil)
    }

    // MARK: - Snapshot Provider Tests (for guard-else branches)

    @Test("measureCoverage returns nil when before snapshot is nil")
    func testMeasureCoverageNilBefore() {
        // Mock provider that always returns nil
        let nilProvider: () -> CoverageCounters? = { nil }

        let result = measureCoverage(snapshotProvider: nilProvider) {
            // This code should not be executed because before is nil
        }

        #expect(result == nil, "Should return nil when before snapshot is nil")
    }

    @Test("measureCoverage returns nil when after snapshot is nil")
    func testMeasureCoverageNilAfter() {
        var callCount = 0
        // Mock provider that returns a value on first call, nil on second
        let provider: () -> CoverageCounters? = {
            callCount += 1
            if callCount == 1 {
                return CoverageCounters(counters: [1, 2, 3])
            }
            return nil
        }

        var bodyExecuted = false
        let result = measureCoverage(snapshotProvider: provider) {
            bodyExecuted = true
        }

        #expect(bodyExecuted, "Body should have executed")
        #expect(result == nil, "Should return nil when after snapshot is nil")
    }

    @Test("async measureCoverage returns nil when before snapshot is nil")
    func testAsyncMeasureCoverageNilBefore() async {
        // Mock provider that always returns nil
        let nilProvider: () -> CoverageCounters? = { nil }

        let body: () async -> Void = {
            // This code should not be executed because before is nil
        }
        let result = await measureCoverage(snapshotProvider: nilProvider, body)

        #expect(result == nil, "Should return nil when before snapshot is nil")
    }

    @Test("async measureCoverage returns nil when after snapshot is nil")
    func testAsyncMeasureCoverageNilAfter() async {
        var callCount = 0
        // Mock provider that returns a value on first call, nil on second
        let provider: () -> CoverageCounters? = {
            callCount += 1
            if callCount == 1 {
                return CoverageCounters(counters: [1, 2, 3])
            }
            return nil
        }

        var bodyExecuted = false
        let body: () async -> Void = {
            bodyExecuted = true
        }
        let result = await measureCoverage(snapshotProvider: provider, body)

        #expect(bodyExecuted, "Body should have executed")
        #expect(result == nil, "Should return nil when after snapshot is nil")
    }
}
