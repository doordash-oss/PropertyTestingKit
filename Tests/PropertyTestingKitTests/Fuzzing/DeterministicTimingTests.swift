//
//  DeterministicTimingTests.swift
//  PropertyTestingKit
//
//  Tests for time-dependent behavior using controlled DateClient.
//

import Testing
import Foundation
import Clocks
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

/// Helper to create a mock CoverageCountersClient with both snapshot and snapshotCoveredArrays.
private func makeMockCoverageClient(
    countersGenerator: @escaping @Sendable () -> [UInt64]
) -> CoverageCountersClient {
    // Create the snapshotCoveredArrays closure once so we can reuse it
    let snapshotCoveredArraysClosure: @Sendable () -> SparseCoverage? = {
        let counters = countersGenerator()
        var indices: [UInt32] = []
        var counts: [UInt8] = []
        for (index, count) in counters.enumerated() where count > 0 {
            indices.append(UInt32(index))
            counts.append(UInt8(min(count, UInt64(UInt8.max))))
        }
        return SparseCoverage(indices: indices, counts: counts)
    }

    return CoverageCountersClient(
        snapshot: {
            let counters = countersGenerator()
            return SanCovCounters(counters: counters)
        },
        snapshotCoveredArrays: snapshotCoveredArraysClosure,
        isAvailable: { true },
        beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
        endMeasurement: { _ in },
        snapshotCoveredArraysWithContext: { _ in snapshotCoveredArraysClosure() }
    )
}

/// A minimal MutatorProviding type with a single seed for predictable test behavior.
private struct SingleSeedInt: MutatorProviding, Codable, Sendable, Equatable {
    let value: Int

    static var defaultMutator: AnyMutator<SingleSeedInt> {
        AnyMutator(seeds: [SingleSeedInt(value: 0)]) { current in
            [SingleSeedInt(value: current.value + 1)]
        }
    }
}

@Suite("Deterministic Timing")
struct DeterministicTimingTests {

    // MARK: - FuzzEngine Time Limit Tests

    @Suite("FuzzEngine Time Limit", .serialized)
    struct FuzzEngineTimeLimitTests {

        @Test("FuzzEngine stops when maxDuration is reached")
        func testStopsAtMaxDuration() async {
            // Use SyncBox for synchronous DateClient access
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let result = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
                $0.coverageCounters = makeMockCoverageClient {
                    var counters = [UInt64](repeating: 0, count: 100)
                    let timeIndex = Int(currentTime.value.timeIntervalSince1970) % 100
                    counters[timeIndex] = UInt64(timeIndex + 1)
                    return counters
                }
            } operation: {
                let config = FuzzEngine<SingleSeedInt>.Config(
                    maxIterations: 1000,
                    maxDuration: .seconds(10),
                    verbose: false,
                    mutationBatchSize: 1  // Use batch size 1 for precise time limit testing
                )

                let engine = FuzzEngine<SingleSeedInt>(mutators: SingleSeedInt.defaultMutator, config: config, corpusDirectory: nil)
                return await engine.run { _ in
                    // Advance time by 11 seconds each test (exceeds 10s limit after first test)
                    currentTime.update { $0 = $0.addingTimeInterval(11) }
                }
            }

            // With 11s per test and 10s limit, should stop after very few tests
            #expect(result.stats.stopReason == FuzzStats.StopReason.timeLimit)
            #expect(result.stats.totalInputs <= 10, "Should stop early due to time limit")
            #expect(result.stats.duration >= 10, "Duration should exceed time limit")
        }

        @Test("FuzzEngine duration is computed correctly")
        func testDurationComputation() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 1000))
            let testCount = SyncBox(0)

            let result = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
                $0.coverageCounters = makeMockCoverageClient {
                    var counters = [UInt64](repeating: 0, count: 100)
                    let count = testCount.value
                    counters[count % 100] = UInt64(count + 1)
                    return counters
                }
            } operation: {
                let config = FuzzEngine<SingleSeedInt>.Config(
                    maxIterations: 5,
                    maxDuration: .seconds(100),
                    verbose: false
                )

                let engine = FuzzEngine<SingleSeedInt>(mutators: SingleSeedInt.defaultMutator, config: config, corpusDirectory: nil)
                return await engine.run { _ in
                    // Advance time by exactly 2.5 seconds each test
                    testCount.update { $0 += 1 }
                    currentTime.update { $0 = $0.addingTimeInterval(2.5) }
                }
            }

            // Duration = totalInputs * 2.5 seconds
            let expectedDuration = Double(result.stats.totalInputs) * 2.5
            #expect(result.stats.duration == expectedDuration, "Duration should match total inputs * time per test")
        }

        @Test("FuzzEngine prefers iteration limit over time limit when iterations complete first")
        func testIterationLimitBeforeTimeLimit() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let result = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
                $0.coverageCounters = makeMockCoverageClient {
                    var counters = [UInt64](repeating: 0, count: 100)
                    let timeIndex = Int(currentTime.value.timeIntervalSince1970) % 100
                    counters[timeIndex] = UInt64(timeIndex + 1)
                    return counters
                }
            } operation: {
                let config = FuzzEngine<SingleSeedInt>.Config(
                    maxIterations: 5,
                    maxDuration: .seconds(1000),  // Very long time limit
                    verbose: false
                )

                let engine = FuzzEngine<SingleSeedInt>(mutators: SingleSeedInt.defaultMutator, config: config, corpusDirectory: nil)
                return await engine.run { _ in
                    // Only advance 1 second per test
                    currentTime.update { $0 = $0.addingTimeInterval(1) }
                }
            }

            #expect(result.stats.stopReason == FuzzStats.StopReason.iterationLimit)
            // Duration = totalInputs * 1 second
            #expect(result.stats.duration == Double(result.stats.totalInputs))
        }
    }

    // MARK: - TestCaseShrinker Timeout Tests

    @Suite("TestCaseShrinker Timeout")
    struct TestCaseShrinkerTimeoutTests {

        @Test("Shrinker sets timedOut flag when timeout exceeded")
        func testTimeoutFlag() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let (minimized, stats) = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                    maxExecutions: 1000,
                    timeout: 5.0
                ))

                return await shrinker.shrink(input: Array(0..<100)) { candidate in
                    // Advance time by 2 seconds per test
                    currentTime.update { $0 = $0.addingTimeInterval(2) }
                    return candidate.contains(50) ? .fail : .pass
                }
            }

            #expect(stats.timedOut, "Should have timed out")
            #expect(!stats.maxExecutionsReached, "Should not have hit max executions")
            #expect(minimized.contains(50), "Should still contain failing element")
        }

        @Test("Shrinker duration is computed correctly")
        func testDurationComputation() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 100))

            let (_, stats) = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                    maxExecutions: 10,
                    timeout: 1000
                ))

                return await shrinker.shrink(input: [1, 2, 3, 4, 5]) { candidate in
                    // Each test takes exactly 0.5 seconds
                    currentTime.update { $0 = $0.addingTimeInterval(0.5) }
                    return candidate.contains(3) ? .fail : .pass
                }
            }

            // Duration should be number of tests * 0.5 seconds
            #expect(stats.duration == Double(stats.candidatesTested) * 0.5)
        }

        @Test("Shrinker stops immediately when timeout reached mid-shrink")
        func testImmediateStop() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let (minimized, stats) = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                    maxExecutions: 1000,
                    timeout: 10.0
                ))

                // Use a large array where failure requires a specific element
                // This ensures shrinking can't immediately minimize to empty
                return await shrinker.shrink(input: Array(0..<1000)) { candidate in
                    // Advance time by 5 seconds (should stop after 2-3 tests)
                    currentTime.update { $0 = $0.addingTimeInterval(5) }
                    // Require element 500 to be present for failure
                    return candidate.contains(500) ? .fail : .pass
                }
            }

            #expect(stats.timedOut)
            #expect(stats.candidatesTested <= 3, "Should stop after few tests due to timeout")
            #expect(minimized.contains(500), "Should preserve failing element")
        }
    }

    // MARK: - SimpleCoveragePlateauDetector Duration Tests

    @Suite("SimpleCoveragePlateauDetector Duration")
    struct SimpleCoveragePlateauDetectorDurationTests {

        @Test("PlateauStats duration tracks elapsed time")
        func testDurationTracking() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let stats = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let config = SimpleCoveragePlateauDetector.Config(
                    windowSize: 10,
                    minDiscoveryRate: 0.01,
                    confirmationWindows: 2,
                    enabled: true
                )
                var detector = SimpleCoveragePlateauDetector(config: config)

                // First record sets startTime
                detector.record(discoveredNewCoverage: true)
                currentTime.update { $0 = $0.addingTimeInterval(5) }

                detector.record(discoveredNewCoverage: false)
                currentTime.update { $0 = $0.addingTimeInterval(3) }

                detector.record(discoveredNewCoverage: true)
                currentTime.update { $0 = $0.addingTimeInterval(2) }

                return detector.stats()
            }

            // Total: 5 + 3 + 2 = 10 seconds
            #expect(stats.duration == 10.0)
            #expect(stats.totalIterations == 3)
            #expect(stats.totalDiscoveries == 2)
        }

        @Test("PlateauStats duration is zero before any records")
        func testZeroDurationBeforeRecords() async {
            let stats = withDependencies {
                $0.dateClient = DateClient.constant(Date())
            } operation: {
                let config = SimpleCoveragePlateauDetector.Config(enabled: true)
                let detector = SimpleCoveragePlateauDetector(config: config)
                return detector.stats()
            }

            #expect(stats.duration == 0)
        }

        @Test("PlateauStats discoveryRate uses duration")
        func testDiscoveryRateCalculation() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let stats = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let config = SimpleCoveragePlateauDetector.Config(
                    windowSize: 100,
                    minDiscoveryRate: 0.001,
                    confirmationWindows: 10,
                    enabled: true
                )
                var detector = SimpleCoveragePlateauDetector(config: config)

                // Record 10 discoveries over 20 seconds
                for _ in 0..<10 {
                    detector.record(discoveredNewCoverage: true)
                    currentTime.update { $0 = $0.addingTimeInterval(2) }
                }

                return detector.stats()
            }

            // 10 discoveries / 20 seconds = 0.5 discoveries per second
            #expect(stats.discoveriesPerSecond == 0.5)
        }
    }

    // MARK: - ShrinkStats Duration Tests

    @Suite("ShrinkStats Duration")
    struct ShrinkStatsDurationTests {

        @Test("ShrinkStats captures exact duration")
        func testExactDuration() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 500))

            let (_, stats) = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<String>(config: ShrinkConfig(
                    maxExecutions: 5,
                    timeout: 100
                ))

                return await shrinker.shrink(input: "hello world") { candidate in
                    currentTime.update { $0 = $0.addingTimeInterval(1.25) }
                    return candidate.contains("o") ? .fail : .pass
                }
            }

            // Duration should be a multiple of 1.25
            #expect(stats.duration.truncatingRemainder(dividingBy: 1.25) == 0)
        }

        @Test("ShrinkStats duration reflects actual work done")
        func testDurationReflectsWork() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let (_, stats) = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                    maxExecutions: 20,
                    timeout: 1000
                ))

                return await shrinker.shrink(input: [1, 2, 3, 4, 5]) { _ in
                    // Use 1 second increments to avoid floating point precision issues
                    currentTime.update { $0 = $0.addingTimeInterval(1) }
                    return .fail
                }
            }

            // Duration should equal candidatesTested since each takes 1 second
            #expect(stats.duration == Double(stats.candidatesTested))
            #expect(stats.candidatesTested > 0)
        }
    }

    // MARK: - MultiComponentShrinker Time Budget Tests

    @Suite("MultiComponentShrinker Time Budget")
    struct MultiComponentShrinkerTimeBudgetTests {

        @Test("MultiComponentShrinker allocates remaining time to second component")
        func testTimeBudgetAllocation() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let (_, stats) = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = MultiComponentShrinker(config: ShrinkConfig(
                    maxExecutions: 100,
                    timeout: 10.0  // 10 second total budget
                ))

                return await shrinker.shrink(input: ([1, 2, 3], "abc")) { (arr, str) in
                    // Use time-based phase detection instead of counters
                    // Phase A: first 5 seconds (0.5s per test * 10 tests)
                    // Phase B: after 5 seconds (0.3s per test)
                    let timeValue = currentTime.value
                    if timeValue.timeIntervalSince1970 < 5 {
                        // Component A takes 0.5 seconds per test
                        currentTime.update { $0 = $0.addingTimeInterval(0.5) }
                    } else {
                        // Component B takes 0.3 seconds per test
                        currentTime.update { $0 = $0.addingTimeInterval(0.3) }
                    }
                    return (arr.contains(2) && str.contains("b")) ? .fail : .pass
                }
            }

            // Total duration should be sum of both components
            #expect(stats.duration <= 10.5, "Should respect overall time budget")
        }

        @Test("MultiComponentShrinker stops second component when time exhausted")
        func testSecondComponentTimeBudgetExhaustion() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

            let (minimized, stats) = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = MultiComponentShrinker(config: ShrinkConfig(
                    maxExecutions: 1000,
                    timeout: 8.0
                ))

                return await shrinker.shrink(input: (Array(0..<50), "abcdefghij")) { (arr, str) in
                    // Use time-based phase detection
                    let timeValue = currentTime.value
                    if timeValue.timeIntervalSince1970 < 6 {
                        // Component A consumes 6 seconds on first call
                        currentTime.update { $0 = $0.addingTimeInterval(6) }
                    } else {
                        // Component B gets only 2 seconds remaining
                        currentTime.update { $0 = $0.addingTimeInterval(1) }
                    }
                    return (arr.contains(25) && str.contains("e")) ? .fail : .pass
                }
            }

            #expect(minimized.0.contains(25), "First component result preserved")
            #expect(minimized.1.contains("e"), "Second component result preserved")
            #expect(stats.timedOut, "Should have timed out")
        }

        @Test("MultiComponentShrinker duration is sum of both phases")
        func testTotalDuration() async {
            let currentTime = SyncBox(Date(timeIntervalSince1970: 1000))

            let (_, stats) = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = MultiComponentShrinker(config: ShrinkConfig(
                    maxExecutions: 10,
                    timeout: 100
                ))

                return await shrinker.shrink(input: ([1, 2], "ab")) { (arr, str) in
                    // Each test takes 0.75 seconds
                    currentTime.update { $0 = $0.addingTimeInterval(0.75) }
                    return (arr.contains(1) && str.contains("a")) ? .fail : .pass
                }
            }

            // Duration should reflect all tests across both components
            let expectedDuration = Double(stats.candidatesTested) * 0.75
            #expect(stats.duration == expectedDuration)
        }
    }

    // MARK: - awaitSourceLocationPreWarming Tests

    @Suite("awaitSourceLocationPreWarming")
    struct AwaitSourceLocationPreWarmingTests {

        @Test("completes without hanging when prewarming finishes")
        func testCompletesWhenPrewarmingFinishes() async {
            // Start prewarming
            await SanCovCounters.startPreWarmingSourceLocations()

            // Should complete (either prewarm finishes or times out)
            await SanCovCounters.awaitSourceLocationPreWarming(timeout: .seconds(5))

            // If we get here, it completed successfully
        }

        @Test("respects timeout via injected clock")
        func testRespectsTimeout() async {
            let testClock = TestClock()

            // Start prewarming first
            await SanCovCounters.startPreWarmingSourceLocations()

            // Start awaiting with injected clock
            async let awaitTask: Void = withDependencies {
                $0.continuousClockClient = testClock
            } operation: {
                await SanCovCounters.awaitSourceLocationPreWarming(timeout: .seconds(1))
            }

            // Advance clock past timeout
            await testClock.advance(by: .seconds(2))

            // Should complete due to timeout
            await awaitTask
        }
    }

    // MARK: - runWithTimeout Tests

    @Suite("runWithTimeout")
    struct RunWithTimeoutTests {

        @Test("returns false when task completes before timeout")
        func testCompletesInTime() async throws {
            let testClock = TestClock()

            let timedOut = try await withDependencies {
                $0.continuousClockClient = testClock
            } operation: {
                await runWithTimeout(timeout: .seconds(10)) {
                    // Task completes immediately without awaiting
                }
            }

            #expect(!timedOut, "Task that completes before timeout should return false")
        }

        @Test("returns true when timeout fires first")
        func testExceedsTimeout() async throws {
            let testClock = TestClock()
            let taskStarted = SyncBox(false)

            async let result: Bool = withDependencies {
                $0.continuousClockClient = testClock
            } operation: {
                try await runWithTimeout(timeout: .seconds(1)) {
                    taskStarted.update { $0 = true }
                    // Task tries to sleep for much longer than timeout
                    try await Task.sleep(for: .seconds(100))
                }
            }

            // Wait for task to start
            while !taskStarted.value {
                await Task.yield()
            }

            // Advance clock past the timeout
            await testClock.advance(by: .seconds(2))

            let timedOut = try await result
            #expect(timedOut, "When timeout fires first, should return true")
        }

        @Test("propagates errors from task")
        func testPropagatesErrors() async throws {
            struct TestError: Error {}
            let testClock = TestClock()

            do {
                _ = try await withDependencies {
                    $0.continuousClockClient = testClock
                } operation: {
                    try await runWithTimeout(timeout: .seconds(10)) {
                        throw TestError()
                    }
                }
                Issue.record("Should have thrown TestError")
            } catch is TestError {
                // Expected
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - FuzzEngine Per-Input Timeout Tests

    @Suite("FuzzEngine Per-Input Timeout")
    struct FuzzEnginePerInputTimeoutTests {

        @Test("cancels slow inputs")
        func testFuzzEnginePerInputTimeout() async {
            let testClock = TestClock()
            let inputsTested = SyncBox<[Int]>([])
            let inputsCompleted = SyncBox<[Int]>([])

            async let result = withDependencies {
                $0.coverageCounters = makeMockCoverageClient {
                    [UInt64](repeating: 1, count: 100)
                }
                $0.continuousClockClient = testClock
            } operation: {
                let config = FuzzEngine<Int>.Config(
                    maxIterations: 3,
                    maxDuration: .seconds(300),
                    verbose: false,
                    perInputTimeout: .seconds(1)
                )

                let engine = FuzzEngine<Int>(mutators: Int.defaultMutator, config: config, corpusDirectory: nil)
                return await engine.run { input in
                    inputsTested.update { $0.append(input) }
                    // All inputs try to sleep longer than timeout
                    try await Task.sleep(for: .seconds(100))
                    inputsCompleted.update { $0.append(input) }
                }
            }

            // Wait for first input to be tested
            while inputsTested.value.isEmpty {
                await Task.yield()
            }

            // Advance clock past the per-input timeout multiple times
            // to allow the fuzzer to process multiple inputs
            for _ in 0..<10 {
                await testClock.advance(by: .seconds(2))
                await Task.yield()
            }

            let finalResult = await result

            #expect(finalResult.stats.totalInputs > 0, "Should have tested inputs")
            #expect(!inputsTested.value.isEmpty, "Should have started testing inputs")
            // All inputs should timeout since they sleep for 100s but timeout is 1s
            #expect(inputsCompleted.value.isEmpty, "All inputs should timeout")
        }

        @Test("allows all inputs to complete without perInputTimeout")
        func testNoTimeoutAllowsAllInputs() async {
            let completedInputs = SyncBox(0)

            let result = await withDependencies {
                $0.coverageCounters = makeMockCoverageClient {
                    var counters = [UInt64](repeating: 0, count: 100)
                    counters[completedInputs.value % 100] = 1
                    return counters
                }
                // No clock override needed - perInputTimeout is nil so clock isn't used
            } operation: {
                let config = FuzzEngine<Int>.Config(
                    maxIterations: 3,
                    maxDuration: .seconds(30),
                    verbose: false,
                    perInputTimeout: nil  // No timeout
                )

                let engine = FuzzEngine<Int>(mutators: Int.defaultMutator, config: config, corpusDirectory: nil)
                return await engine.run { _ in
                    completedInputs.update { $0 += 1 }
                }
            }

            #expect(completedInputs.value > 0, "All tests should complete without timeout")
            #expect(result.stats.totalInputs > 0)
        }

        @Test("only affects slow inputs")
        func testTimeoutOnlyAffectsSlowInputs() async {
            let testClock = TestClock()
            let fastCompleted = SyncBox(0)
            let slowStarted = SyncBox(0)

            async let result = withDependencies {
                $0.coverageCounters = makeMockCoverageClient {
                    [UInt64](repeating: 1, count: 100)
                }
                $0.continuousClockClient = testClock
            } operation: {
                let config = FuzzEngine<Int>.Config(
                    maxIterations: 5,
                    maxDuration: .seconds(300),
                    verbose: false,
                    perInputTimeout: .seconds(1)
                )

                let engine = FuzzEngine<Int>(mutators: Int.defaultMutator, config: config, corpusDirectory: nil)
                return await engine.run { input in
                    if input == 0 {
                        // Fast input - completes immediately
                        fastCompleted.update { $0 += 1 }
                    } else {
                        // Slow inputs - will timeout
                        slowStarted.update { $0 += 1 }
                        try await Task.sleep(for: .seconds(100))
                    }
                }
            }

            // Advance clock to trigger timeouts for slow inputs
            for _ in 0..<10 {
                await testClock.advance(by: .seconds(2))
                await Task.yield()
            }

            let finalResult = await result

            #expect(finalResult.stats.totalInputs > 0, "Should have tested inputs")
            // Input 0 should complete since it's fast (doesn't await the clock)
            #expect(fastCompleted.value >= 1, "Fast input (0) should complete")
        }
    }
}
