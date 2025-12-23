//
//  DeterministicTimingTests.swift
//  PropertyTestingKit
//
//  Tests for time-dependent behavior using controlled DateClient.
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

/// A minimal Fuzzable type with a single seed for predictable test behavior.
private struct SingleSeedInt: Fuzzable, Codable, Sendable, Equatable {
    let value: Int

    static var fuzz: [SingleSeedInt] { [SingleSeedInt(value: 0)] }

    func mutate() -> [SingleSeedInt] {
        [SingleSeedInt(value: value + 1)]
    }
}

@Suite("Deterministic Timing")
struct DeterministicTimingTests {

    // MARK: - FuzzEngine Time Limit Tests

    @Suite("FuzzEngine Time Limit", .serialized)
    struct FuzzEngineTimeLimitTests {

        @Test("FuzzEngine stops when maxDuration is reached")
        func testStopsAtMaxDuration() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))
            let testCounter = Synchronized(0)

            let snapshotFn = { @Sendable in 
                var counters = [UInt64](repeating: 0, count: 100)
                await counters[testCounter.value % 100] = UInt64(testCounter.value + 1)
                return SanCovCounters(counters: counters)
            }

            let result = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
                $0.coverageCounters = CoverageCountersClient(
                    snapshot: snapshotFn,
                    reset: {},
                    isAvailable: { true }
                )
            } operation: {
                let config = FuzzEngine<SingleSeedInt>.Config(
                    maxIterations: 1000,
                    maxDuration: 10,
                    verbose: false,
                    mutationBatchSize: 1  // Use batch size 1 for precise time limit testing
                )

                let engine = FuzzEngine<SingleSeedInt>(config: config, corpusDirectory: nil)
                return await engine.run { _ in
                    await testCounter.update { $0 += 1 }
                    // Advance time by 11 seconds each test (exceeds 10s limit after first test)
                    currentTime.addInterval(11)
                }
            }

            // With 11s per test and 10s limit, should stop after very few tests
            #expect(result.stats.stopReason == FuzzStats.StopReason.timeLimit)
            #expect(result.stats.totalInputs <= 10, "Should stop early due to time limit")
            #expect(result.stats.duration >= 10, "Duration should exceed time limit")
        }

        @Test("FuzzEngine duration is computed correctly")
        func testDurationComputation() async {
            // Use actor to safely manage mutable state
            final class TestState: @unchecked Sendable {
                var currentTime = Date(timeIntervalSince1970: 1000)
                var testCount = 0
                let lock = NSLock()

                func advanceTime(by interval: TimeInterval) {
                    lock.lock()
                    testCount += 1
                    currentTime = currentTime.addingTimeInterval(interval)
                    lock.unlock()
                }

                func now() -> Date {
                    lock.lock()
                    defer { lock.unlock() }
                    return currentTime
                }

                func makeCounters() -> SanCovCounters {
                    lock.lock()
                    defer { lock.unlock() }
                    var counters = [UInt64](repeating: 0, count: 100)
                    counters[testCount % 100] = UInt64(testCount + 1)
                    return SanCovCounters(counters: counters)
                }
            }

            let state = TestState()

            let result = await withDependencies {
                $0.dateClient = DateClient(now: { state.now() })
                $0.coverageCounters = CoverageCountersClient(
                    snapshot: { state.makeCounters() },
                    reset: {},
                    isAvailable: { true }
                )
            } operation: {
                var config = FuzzEngine<SingleSeedInt>.Config(
                    maxIterations: 5,
                    maxDuration: 100,
                    verbose: false
                )
                config.enableValueProfile = false  // Disable to avoid C library interaction

                let engine = FuzzEngine<SingleSeedInt>(config: config, corpusDirectory: nil)
                return await engine.run { _ in
                    // Advance time by exactly 2.5 seconds each test
                    state.advanceTime(by: 2.5)
                }
            }

            // Duration = totalInputs * 2.5 seconds
            let expectedDuration = Double(result.stats.totalInputs) * 2.5
            #expect(result.stats.duration == expectedDuration, "Duration should match total inputs * time per test")
        }

        @Test("FuzzEngine prefers iteration limit over time limit when iterations complete first")
        func testIterationLimitBeforeTimeLimit() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))
            let testCounter = ThreadSafeCounter()

            // Use varying coverage so corpus grows and mutation has options
            let snapshotFn: @Sendable () -> SanCovCounters? = {
                var counters = [UInt64](repeating: 0, count: 100)
                counters[testCounter.value % 100] = UInt64(testCounter.value + 1)
                return SanCovCounters(counters: counters)
            }

            let result = await withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
                $0.coverageCounters = CoverageCountersClient(
                    snapshot: snapshotFn,
                    reset: {},
                    isAvailable: { true }
                )
            } operation: {
                var config = FuzzEngine<SingleSeedInt>.Config(
                    maxIterations: 5,
                    maxDuration: 1000,  // Very long time limit
                    verbose: false
                )
                config.enableValueProfile = false  // Disable to avoid C library interaction

                let engine = FuzzEngine<SingleSeedInt>(config: config, corpusDirectory: nil)
                return await engine.run { _ in
                    testCounter.increment()
                    // Only advance 1 second per test
                    currentTime.addInterval(1)
                }
            }

            #expect(result.stats.stopReason == .iterationLimit)
            // Duration = totalInputs * 1 second
            #expect(result.stats.duration == Double(result.stats.totalInputs))
        }
    }

    // MARK: - TestCaseShrinker Timeout Tests

    @Suite("TestCaseShrinker Timeout")
    struct TestCaseShrinkerTimeoutTests {

        @Test("Shrinker sets timedOut flag when timeout exceeded")
        func testTimeoutFlag() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))

            let (minimized, stats) = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                    maxExecutions: 1000,
                    timeout: 5.0
                ))

                return shrinker.shrink(input: Array(0..<100)) { candidate in
                    // Advance time by 2 seconds per test
                    currentTime.addInterval(2)
                    return candidate.contains(50) ? .fail : .pass
                }
            }

            #expect(stats.timedOut, "Should have timed out")
            #expect(!stats.maxExecutionsReached, "Should not have hit max executions")
            #expect(minimized.contains(50), "Should still contain failing element")
        }

        @Test("Shrinker duration is computed correctly")
        func testDurationComputation() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 100))
            let testCounter = ThreadSafeCounter()

            let (_, stats) = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                    maxExecutions: 10,
                    timeout: 1000
                ))

                return shrinker.shrink(input: [1, 2, 3, 4, 5]) { candidate in
                    testCounter.increment()
                    // Each test takes exactly 0.5 seconds
                    currentTime.addInterval(0.5)
                    return candidate.contains(3) ? .fail : .pass
                }
            }

            // Duration should be number of tests * 0.5 seconds
            #expect(stats.duration == Double(testCounter.value) * 0.5)
        }

        @Test("Shrinker stops immediately when timeout reached mid-shrink")
        func testImmediateStop() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))
            let testsRunCounter = ThreadSafeCounter()

            let (minimized, stats) = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                    maxExecutions: 1000,
                    timeout: 10.0
                ))

                // Use a large array where failure requires a specific element
                // This ensures shrinking can't immediately minimize to empty
                return shrinker.shrink(input: Array(0..<1000)) { candidate in
                    testsRunCounter.increment()
                    // Advance time by 5 seconds (should stop after 2-3 tests)
                    currentTime.addInterval(5)
                    // Require element 500 to be present for failure
                    return candidate.contains(500) ? .fail : .pass
                }
            }

            #expect(stats.timedOut)
            #expect(testsRunCounter.value <= 3, "Should stop after few tests due to timeout")
            #expect(minimized.contains(500), "Should preserve failing element")
        }
    }

    // MARK: - CoveragePlateauDetector Duration Tests

    @Suite("CoveragePlateauDetector Duration")
    struct CoveragePlateauDetectorDurationTests {

        @Test("PlateauStats duration tracks elapsed time")
        func testDurationTracking() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))

            let stats = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let config = CoveragePlateauDetector.Config(
                    windowSize: 10,
                    minDiscoveryRate: 0.01,
                    confirmationWindows: 2,
                    enabled: true
                )
                var detector = CoveragePlateauDetector(config: config)

                // First record sets startTime
                detector.record(discoveredNewCoverage: true)
                currentTime.addInterval(5)

                detector.record(discoveredNewCoverage: false)
                currentTime.addInterval(3)

                detector.record(discoveredNewCoverage: true)
                currentTime.addInterval(2)

                return detector.stats
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
                let config = CoveragePlateauDetector.Config(enabled: true)
                let detector = CoveragePlateauDetector(config: config)
                return detector.stats
            }

            #expect(stats.duration == 0)
        }

        @Test("PlateauStats discoveryRate uses duration")
        func testDiscoveryRateCalculation() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))

            let stats = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let config = CoveragePlateauDetector.Config(
                    windowSize: 100,
                    minDiscoveryRate: 0.001,
                    confirmationWindows: 10,
                    enabled: true
                )
                var detector = CoveragePlateauDetector(config: config)

                // Record 10 discoveries over 20 seconds
                for i in 0..<10 {
                    detector.record(discoveredNewCoverage: true)
                    currentTime.addInterval(2)
                }

                return detector.stats
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
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 500))

            let (_, stats) = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<String>(config: ShrinkConfig(
                    maxExecutions: 5,
                    timeout: 100
                ))

                return shrinker.shrink(input: "hello world") { candidate in
                    currentTime.addInterval(1.25)
                    return candidate.contains("o") ? .fail : .pass
                }
            }

            // Duration should be a multiple of 1.25
            #expect(stats.duration.truncatingRemainder(dividingBy: 1.25) == 0)
        }

        @Test("ShrinkStats duration reflects actual work done")
        func testDurationReflectsWork() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))
            let workUnitsCounter = ThreadSafeCounter()

            let (_, stats) = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                    maxExecutions: 20,
                    timeout: 1000
                ))

                return shrinker.shrink(input: [1, 2, 3, 4, 5]) { _ in
                    workUnitsCounter.increment()
                    // Use 1 second increments to avoid floating point precision issues
                    currentTime.addInterval(1)
                    return .fail
                }
            }

            #expect(stats.duration == Double(workUnitsCounter.value))
            #expect(stats.candidatesTested == workUnitsCounter.value)
        }
    }

    // MARK: - MultiComponentShrinker Time Budget Tests

    @Suite("MultiComponentShrinker Time Budget")
    struct MultiComponentShrinkerTimeBudgetTests {

        @Test("MultiComponentShrinker allocates remaining time to second component")
        func testTimeBudgetAllocation() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))
            let componentACounter = ThreadSafeCounter()
            let componentBCounter = ThreadSafeCounter()

            let (_, stats) = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = MultiComponentShrinker(config: ShrinkConfig(
                    maxExecutions: 100,
                    timeout: 10.0  // 10 second total budget
                ))

                return shrinker.shrink(input: ([1, 2, 3], "abc")) { (arr, str) in
                    if componentACounter.value < 10 {
                        componentACounter.increment()
                        // Component A takes 0.5 seconds per test (5 seconds total)
                        currentTime.addInterval(0.5)
                    } else {
                        componentBCounter.increment()
                        // Component B takes 0.3 seconds per test
                        currentTime.addInterval(0.3)
                    }
                    return (arr.contains(2) && str.contains("b")) ? .fail : .pass
                }
            }

            // Total duration should be sum of both components
            #expect(stats.duration <= 10.5, "Should respect overall time budget")
        }

        @Test("MultiComponentShrinker stops second component when time exhausted")
        func testSecondComponentTimeBudgetExhaustion() async {
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))
            let inPhaseB = ThreadSafeFlag()  // false = component A, true = component B

            let (minimized, stats) = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = MultiComponentShrinker(config: ShrinkConfig(
                    maxExecutions: 1000,
                    timeout: 8.0
                ))

                return shrinker.shrink(input: (Array(0..<50), "abcdefghij")) { (arr, str) in
                    if !inPhaseB.isSet {
                        // Component A consumes 6 seconds
                        currentTime.addInterval(6)
                        inPhaseB.set()
                    } else {
                        // Component B gets only 2 seconds remaining
                        currentTime.addInterval(1)
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
            let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 1000))

            let (_, stats) = withDependencies {
                $0.dateClient = DateClient(now: { currentTime.value })
            } operation: {
                let shrinker = MultiComponentShrinker(config: ShrinkConfig(
                    maxExecutions: 10,
                    timeout: 100
                ))

                return shrinker.shrink(input: ([1, 2], "ab")) { (arr, str) in
                    // Each test takes 0.75 seconds
                    currentTime.addInterval(0.75)
                    return (arr.contains(1) && str.contains("a")) ? .fail : .pass
                }
            }

            // Duration should reflect all tests across both components
            let expectedDuration = Double(stats.candidatesTested) * 0.75
            #expect(stats.duration == expectedDuration)
        }
    }
}
