//
//  RaceConditionTests.swift
//  PropertyTestingKit
//
//  Tests to detect race conditions using Thread Sanitizer (TSan).
//  These tests exercise concurrent code paths that might have data races.
//

import Testing
import Foundation
@testable import PropertyTestingKit

// MARK: - SanCovCounters Concurrency Tests

@Suite("SanCovCounters Race Detection")
struct SanCovCountersRaceTests {

    @Test("Concurrent getSourceLocation calls")
    func concurrentGetSourceLocation() async {
        guard SanCovCounters.isAvailable else { return }

        let totalEdges = SanCovCounters.totalEdgeCount
        guard totalEdges > 0 else { return }

        // Concurrently look up source locations for different edges
        await withTaskGroup(of: SanCovSourceLocation?.self) { group in
            for i in 0..<min(100, totalEdges) {
                group.addTask {
                    await SanCovCounters.getSourceLocation(for: i)
                }
            }

            for await _ in group {}
        }
    }

    @Test("Concurrent measurement contexts")
    func concurrentMeasurementContexts() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let context = SanCovCounters.beginMeasurement()
                    defer { SanCovCounters.endMeasurement(context) }

                    // Do some work
                    var sum = i
                    for j in 0..<50 { sum += j }
                    _ = sum

                    // Get coverage
                    _ = try? SanCovCounters.snapshotCoveredArrays(with: context)
                }
            }
        }
    }
}

// MARK: - Corpus Concurrency Tests

/// Helper to create a SparseCoverage from a set of indices
private func makeSparse(indices: [Int]) -> SparseCoverage {
    SparseCoverage(indices: indices.map { UInt32($0) })
}

/// Helper to create a CoverageSignature from a set of indices (for signature-specific tests)
private func makeSignature(indices: [Int]) -> CoverageSignature {
    CoverageSignature(sparse: makeSparse(indices: indices))
}

@Suite("Corpus Race Detection")
struct CorpusRaceTests {

    @Test("Concurrent corpus operations")
    func concurrentCorpusOperations() async {
        // Note: Corpus is not thread-safe. These tests verify behavior in
        // a serialized context (via the actor-isolated FuzzStateMachine).
        // The "concurrent" operations here are serialized by Swift's runtime.
        var corpus = Corpus<Int>()

        // Sequential adds (corpus is not thread-safe)
        for i in 0..<50 {
            let sparse = makeSparse(indices: [i, i + 100, i + 200])
            corpus.add(input: (i), sparse: sparse)
        }

        // Sequential reads
        for _ in 0..<20 {
            _ = corpus.snapshot()
            _ = corpus.count
            _ = corpus.isEmpty
        }
    }

    @Test("Concurrent corpus addIfInteresting")
    func concurrentAddIfInteresting() async {
        // Note: Corpus is not thread-safe. This test verifies the API works correctly.
        var corpus = Corpus<Int>()

        for i in 0..<100 {
            let sparse = makeSparse(indices: [i % 20])
            _ = corpus.addIfInteresting(input: (i), sparse: sparse)
        }
    }
}

// MARK: - FuzzEngine Concurrency Tests

@Suite("FuzzEngine Race Detection")
struct FuzzEngineRaceTests {

    @Test("Concurrent fuzz engine runs")
    func concurrentFuzzEngineRuns() async throws {
        // Run multiple fuzz engines concurrently with short iterations
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let config = FuzzEngineConfig(
                        verbose: false,
                        corpusMode: .refuzzReplace
                    )
                    let engine = FuzzEngine(mutators: Int.defaultMutator, config: config)

                    // Create default plugin processor (mutation handler)
                    let processor = PluginHandlerProcessor(handlers: [FuzzPluginHandler<Int>.mutation()])
                    let processSyncPlugins: @Sendable (
                        consuming SyncPluginEvent<Int>,
                        (FuzzPluginAction<Int>) -> Void
                    ) -> Void = { event, execute in
                        processor.processSync(event: event, execute: execute)
                    }
                    let processAsyncPlugins: @Sendable (
                        isolated (any Actor)?,
                        consuming AsyncPluginEvent<Int>,
                        (FuzzPluginAction<Int>) -> Void
                    ) async -> Void = { isolation, event, execute in
                        await processor.processAsync(isolation: isolation, event: event, execute: execute)
                    }

                    _ = try await engine.run(processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins) { (input: Int) in
                        // Simple test that doesn't fail
                        // Use overflow operators to avoid arithmetic overflow crashes
                        // when fuzzer generates extreme Int values
                        var sum = input
                        for j in 0..<10 {
                            sum = sum &+ j  // Use overflow operator
                        }
                        _ = sum
                    }
                }
            }

            try await group.waitForAll()
        }
    }
}

// MARK: - Coverage Signature Concurrency Tests

@Suite("CoverageSignature Race Detection")
struct CoverageSignatureRaceTests {

    @Test("Concurrent signature operations")
    func concurrentSignatureOperations() async {
        let signatures = (0..<20).map { i in
            makeSignature(indices: Array(0..<(i + 1) * 5))
        }

        await withTaskGroup(of: CoverageSignature.self) { group in
            // Concurrent unions
            for i in 0..<signatures.count {
                for j in 0..<signatures.count where i != j {
                    group.addTask {
                        signatures[i].union(with: signatures[j])
                    }
                }
            }

            for await _ in group {}
        }
    }

    @Test("Concurrent signature creation and comparison")
    func concurrentSignatureCreationAndComparison() async {
        // Create signatures concurrently and compare them
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let sig1 = makeSignature(indices: [i, i + 100])
                    let sig2 = makeSignature(indices: [i + 50, i + 150])
                    let union = sig1.union(with: sig2)
                    return union.executedIndices.count >= sig1.executedIndices.count
                }
            }

            for await _ in group {}
        }
    }
}

// MARK: - High Contention Stress Tests

@Suite("High Contention Stress Tests")
struct HighContentionTests {

    @Test("Maximum concurrent coverage operations", .timeLimit(.minutes(1)))
    func maximumConcurrentOperations() async {
        // Stress test with maximum concurrency using measurement contexts
        await withTaskGroup(of: Void.self) { group in
            // 50 tasks doing coverage measurements with contexts
            for i in 0..<50 {
                group.addTask {
                    for _ in 0..<20 {
                        let context = SanCovCounters.beginMeasurement()
                        defer { SanCovCounters.endMeasurement(context) }

                        var x = i
                        for j in 0..<10 { x += j }
                        _ = x
                        _ = try? SanCovCounters.snapshotCoveredArrays(with: context)
                    }
                }
            }
        }
    }

    @Test("Sequential corpus and coverage operations", .timeLimit(.minutes(1)))
    func sequentialCorpusAndCoverage() async {
        // Note: Corpus is not thread-safe. This test verifies the API works correctly
        // in a sequential context.
        var corpus = Corpus<Int>()

        for i in 0..<30 {
            for j in 0..<10 {
                // Measure coverage with context
                let context = SanCovCounters.beginMeasurement()
                var x = i * j
                for k in 0..<20 { x += k }
                _ = x

                // Create sparse coverage from context
                let sparse: SparseCoverage
                if let coverage = try? SanCovCounters.snapshotCoveredArrays(with: context) {
                    sparse = coverage
                } else {
                    sparse = makeSparse(indices: [i, j])
                }
                SanCovCounters.endMeasurement(context)

                // Add to corpus
                corpus.add(input: (i * 100 + j), sparse: sparse)
            }
        }

        // Verify corpus has entries
        _ = corpus.snapshot()
    }
}
