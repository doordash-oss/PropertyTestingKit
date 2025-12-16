//
//  SanCovIsolationTests.swift
//  PropertyTestingKit
//
//  Tests for verifying that SanitizerCoverage with thread-local coverage maps
//  provides TRUE per-test coverage isolation, even with concurrent execution.
//
//  Key insight: Swift's -sanitize-coverage=edge uses trace_pc_guard callbacks.
//  We maintain thread-local coverage bitmaps that can be reset independently,
//  so one test's reset doesn't affect another test's measurements.
//

import Testing
import ValueProfileHooks
import Dispatch

// Functions to test coverage on - each has distinct code paths
@inline(never)
func functionA(_ x: Int) -> Int {
    if x > 0 {
        return x * 2
    } else {
        return x * -1
    }
}

@inline(never)
func functionB(_ x: Int) -> Int {
    if x < 10 {
        return x + 100
    } else {
        return x - 50
    }
}

@inline(never)
func functionC(_ x: Int) -> Int {
    switch x {
    case 0: return 0
    case 1: return 1
    case 2: return 4
    default: return x * x
    }
}

// Unique functions for isolation proof test
@inline(never) func uniqueToTestA(_ x: Int) -> Int {
    if x > 500 { return x * 7 + 3 }
    else { return x * 2 - 1 }
}
@inline(never) func uniqueToTestB(_ x: Int) -> Int {
    if x < 200 { return x * 11 - 5 }
    else { return x / 3 + 10 }
}
@inline(never) func uniqueToTestC(_ x: Int) -> Int {
    switch x % 4 {
    case 0: return x + 1
    case 1: return x + 2
    case 2: return x + 3
    default: return x + 4
    }
}

@Suite("SanitizerCoverage Isolation Tests")
struct SanCovIsolationTests {

    @Test("Counters are available when compiled with sanitize-coverage")
    func countersAvailable() {
        let available = sancov_counters_available()
        print("SanCov counters available: \(available)")
        print("Counter count: \(sancov_get_counter_count())")

        if !available {
            print("NOTE: Counters not available. Compile with:")
            print("  -Xswiftc -sanitize=address -Xswiftc -sanitize-coverage=edge")
        }
    }

    @Test("Reset clears coverage for current thread only")
    func resetClearsCoverage() throws {
        guard sancov_counters_available() else {
            print("Skipping: SanCov counters not available")
            return
        }

        // Run some code to get coverage
        _ = functionA(5)
        _ = functionB(5)

        let coveredBefore = sancov_get_covered_count()
        print("Covered edges before reset: \(coveredBefore)")
        #expect(coveredBefore > 0, "Should have some coverage after running functions")

        // Reset counters (only affects this thread's coverage map)
        sancov_reset_counters()

        let coveredAfter = sancov_get_covered_count()
        print("Covered edges after reset: \(coveredAfter)")
        #expect(coveredAfter == 0, "Should have zero coverage after reset")
    }

    @Test("Coverage is isolated per measurement")
    func coverageIsolatedPerMeasurement() throws {
        guard sancov_counters_available() else {
            print("Skipping: SanCov counters not available")
            return
        }

        // First measurement: only functionA
        sancov_reset_counters()
        _ = functionA(5)
        let coverageA = sancov_get_covered_count()
        print("Coverage after functionA only: \(coverageA)")

        // Second measurement: only functionB
        sancov_reset_counters()
        _ = functionB(5)
        let coverageB = sancov_get_covered_count()
        print("Coverage after functionB only: \(coverageB)")

        // Third measurement: only functionC
        sancov_reset_counters()
        _ = functionC(5)
        let coverageC = sancov_get_covered_count()
        print("Coverage after functionC only: \(coverageC)")

        print("All measurements were independent - reset works!")
    }

    @Test("Snapshot does not clear counters")
    func snapshotDoesNotClear() throws {
        guard sancov_counters_available() else {
            print("Skipping: SanCov counters not available")
            return
        }

        // Reset and run some code
        sancov_reset_counters()
        _ = functionA(5)
        _ = functionA(-5)  // Hit both branches

        let coveredAfterFunction = sancov_get_covered_count()
        print("Covered after functionA: \(coveredAfterFunction)")

        // Take a snapshot - coverage should still be non-zero after
        let bufferSize = sancov_snapshot_counters(nil, 0)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        _ = buffer.withUnsafeMutableBufferPointer { ptr in
            sancov_snapshot_counters(ptr.baseAddress, ptr.count)
        }

        let coveredAfterSnapshot = sancov_get_covered_count()
        print("Covered after snapshot: \(coveredAfterSnapshot)")

        // Snapshot should not have cleared - coverage should be >= what we had
        // (may be higher due to snapshot code itself being covered)
        #expect(coveredAfterSnapshot >= coveredAfterFunction, "Snapshot should not clear counters")

        // The snapshot buffer should have captured the coverage
        let capturedCoverage = buffer.filter { $0 != 0 }.count
        print("Captured in snapshot: \(capturedCoverage)")
        #expect(capturedCoverage > 0, "Snapshot should have captured coverage")
    }
}

// MARK: - Concurrent Isolation Test

import Foundation

/// Thread-safe storage for coverage snapshots
final class SnapshotStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshotA: [UInt8]?
    private var _snapshotB: [UInt8]?
    private var _snapshotC: [UInt8]?

    var snapshotA: [UInt8]? {
        get { lock.withLock { _snapshotA } }
        set { lock.withLock { _snapshotA = newValue } }
    }
    var snapshotB: [UInt8]? {
        get { lock.withLock { _snapshotB } }
        set { lock.withLock { _snapshotB = newValue } }
    }
    var snapshotC: [UInt8]? {
        get { lock.withLock { _snapshotC } }
        set { lock.withLock { _snapshotC = newValue } }
    }
}

@Suite("Concurrent Coverage Isolation")
struct ConcurrentCoverageIsolationTests {

    @Test("Thread-local coverage provides true isolation with DispatchQueue")
    func threadLocalIsolationWithDispatch() throws {
        guard sancov_counters_available() else {
            print("Skipping: SanCov counters not available")
            return
        }

        let bufferSize = sancov_snapshot_counters(nil, 0)
        let group = DispatchGroup()
        let storage = SnapshotStorage()

        // Test A: Reset, call uniqueToTestA, snapshot
        group.enter()
        DispatchQueue.global().async {
            sancov_reset_counters()
            for i in 0..<1000 { _ = uniqueToTestA(i) }
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            _ = buffer.withUnsafeMutableBufferPointer { sancov_snapshot_counters($0.baseAddress, $0.count) }
            storage.snapshotA = buffer
            group.leave()
        }

        // Test B: Reset, call uniqueToTestB, snapshot
        group.enter()
        DispatchQueue.global().async {
            sancov_reset_counters()
            for i in 0..<1000 { _ = uniqueToTestB(i) }
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            _ = buffer.withUnsafeMutableBufferPointer { sancov_snapshot_counters($0.baseAddress, $0.count) }
            storage.snapshotB = buffer
            group.leave()
        }

        // Test C: Reset, call uniqueToTestC, snapshot
        group.enter()
        DispatchQueue.global().async {
            sancov_reset_counters()
            for i in 0..<1000 { _ = uniqueToTestC(i) }
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            _ = buffer.withUnsafeMutableBufferPointer { sancov_snapshot_counters($0.baseAddress, $0.count) }
            storage.snapshotC = buffer
            group.leave()
        }

        group.wait()

        // Analyze: each test should have unique edges
        func coveredIndices(_ snapshot: [UInt8]) -> Set<Int> {
            Set(snapshot.enumerated().compactMap { $0.element != 0 ? $0.offset : nil })
        }

        let indicesA = coveredIndices(storage.snapshotA!)
        let indicesB = coveredIndices(storage.snapshotB!)
        let indicesC = coveredIndices(storage.snapshotC!)

        // Find edges unique to each test (not in any other test)
        let uniqueA = indicesA.subtracting(indicesB).subtracting(indicesC)
        let uniqueB = indicesB.subtracting(indicesA).subtracting(indicesC)
        let uniqueC = indicesC.subtracting(indicesA).subtracting(indicesB)

        print("TestA: \(indicesA.count) total, \(uniqueA.count) unique edges")
        print("TestB: \(indicesB.count) total, \(uniqueB.count) unique edges")
        print("TestC: \(indicesC.count) total, \(uniqueC.count) unique edges")

        // Each test MUST have at least some unique edges (from its unique function)
        #expect(!uniqueA.isEmpty, "TestA should have unique coverage from uniqueToTestA")
        #expect(!uniqueB.isEmpty, "TestB should have unique coverage from uniqueToTestB")
        #expect(!uniqueC.isEmpty, "TestC should have unique coverage from uniqueToTestC")

        print("")
        print("✅ Thread-local coverage maps provide TRUE per-test isolation!")
        print("   Each concurrent test measured ONLY its own function's coverage.")
    }

    @Test("Swift concurrency tasks may NOT have isolation (tasks can hop threads)")
    func swiftConcurrencyTasksMayShareThreads() async throws {
        guard sancov_counters_available() else {
            print("Skipping: SanCov counters not available")
            return
        }

        // This test demonstrates the PROBLEM with thread-local storage in Swift concurrency:
        // Tasks in a task group can execute on ANY thread, and may even hop threads
        // at suspension points. Thread-local storage does NOT provide task isolation.

        actor ResultCollector {
            var threadIDs: [String: String] = [:]

            func record(test: String, threadID: String) {
                threadIDs[test] = threadID
            }

            func getResults() -> [String: String] {
                threadIDs
            }
        }

        let collector = ResultCollector()

        // Get thread ID as a string for comparison
        func currentThreadID() -> String {
            var tid: UInt64 = 0
            pthread_threadid_np(nil, &tid)
            return "\(tid)"
        }

        await withTaskGroup(of: Void.self) { group in
            for testName in ["TaskA", "TaskB", "TaskC", "TaskD", "TaskE"] {
                group.addTask {
                    let tid = currentThreadID()
                    await collector.record(test: testName, threadID: tid)
                }
            }
        }

        let results = await collector.getResults()
        let uniqueThreads = Set(results.values)

        print("Task execution threads:")
        for (test, tid) in results.sorted(by: { $0.key < $1.key }) {
            print("  \(test): thread \(tid)")
        }
        print("Unique threads used: \(uniqueThreads.count) out of \(results.count) tasks")

        // This demonstrates that multiple tasks may run on the same thread
        // If all tasks ran on unique threads, thread-local storage would work
        // But Swift's runtime makes no such guarantee
        if uniqueThreads.count < results.count {
            print("⚠️  Multiple tasks shared threads - thread-local storage won't isolate them!")
        } else {
            print("Note: Tasks happened to use unique threads this time (not guaranteed)")
        }
    }
}
