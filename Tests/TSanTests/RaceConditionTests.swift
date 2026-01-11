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

    @Test("Concurrent getCoveredLocations calls")
    func concurrentGetCoveredLocations() async {
        // Generate some coverage using a measurement context
        guard let context = SanCovCounters.beginMeasurement() else { return }
        var x = 0
        for i in 0..<100 { x += i }
        _ = x
        SanCovCounters.endMeasurement(context)

        // Then concurrently get covered locations
        await withTaskGroup(of: [SanCovSourceLocation].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await SanCovCounters.getCoveredLocations()
                }
            }

            for await _ in group {}
        }
    }

    @Test("Concurrent lineNumbersAvailable checks")
    func concurrentLineNumbersAvailable() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await SanCovCounters.lineNumbersAvailable()
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
                    guard let context = SanCovCounters.beginMeasurement() else { return }
                    defer { SanCovCounters.endMeasurement(context) }

                    // Do some work
                    var sum = i
                    for j in 0..<50 { sum += j }
                    _ = sum

                    // Get coverage
                    _ = SanCovCounters.snapshotCoveredArrays(with: context)
                }
            }
        }
    }
}

// MARK: - Corpus Concurrency Tests

/// Helper to create a CoverageSignature from a set of indices
private func makeSignature(indices: [Int]) -> CoverageSignature {
    let sparse = SparseCoverage(indices: indices.map { UInt32($0) })
    return CoverageSignature(sparse: sparse)
}

@Suite("Corpus Race Detection")
struct CorpusRaceTests {

    @Test("Concurrent corpus operations")
    func concurrentCorpusOperations() async {
        let corpus = Corpus<Int>(schemaVersion: "1.0.0")

        await withTaskGroup(of: Void.self) { group in
            // Concurrent adds
            for i in 0..<50 {
                group.addTask {
                    let signature = makeSignature(indices: [i, i + 100, i + 200])
                    await corpus.add(input: i, signature: signature)
                }
            }

            // Concurrent reads
            for _ in 0..<20 {
                group.addTask {
                    _ = await corpus.snapshot()
                }
                group.addTask {
                    _ = await corpus.count
                }
                group.addTask {
                    _ = await corpus.isEmpty
                }
            }
        }
    }

    @Test("Concurrent corpus addIfInteresting")
    func concurrentAddIfInteresting() async {
        let corpus = Corpus<Int>(schemaVersion: "1.0.0")

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let signature = makeSignature(indices: [i % 20])
                    return await corpus.addIfInteresting(input: i, signature: signature)
                }
            }

            for await _ in group {}
        }
    }
}

// MARK: - CoverageGapDetector Concurrency Tests

@Suite("CoverageGapDetector Race Detection")
struct CoverageGapDetectorRaceTests {

    @Test("Concurrent gap detection")
    func concurrentGapDetection() async {
        let detector = CoverageGapDetector()

        // Generate some coverage using measurement context
        guard let context = SanCovCounters.beginMeasurement() else { return }
        var x = 0
        for i in 0..<50 { x += i }
        _ = x
        SanCovCounters.endMeasurement(context)

        // Get covered indices
        guard let snapshot = SanCovCounters.snapshot() else { return }
        let coveredIndices = snapshot.coveredIndices

        // Concurrently detect gaps
        await withTaskGroup(of: CoverageGapReport.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await detector.detect(from: coveredIndices)
                }
            }

            for await _ in group {}
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
                    let config = FuzzEngine<Int>.Config(
                        maxIterations: 20,
                        verbose: false,
                        corpusMode: .refuzzReplace
                    )
                    let engine = FuzzEngine(mutators: Int.defaultMutator, config: config)

                    _ = try await engine.run { (input: Int) in
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
                        guard let context = SanCovCounters.beginMeasurement() else { continue }
                        defer { SanCovCounters.endMeasurement(context) }

                        var x = i
                        for j in 0..<10 { x += j }
                        _ = x
                        _ = SanCovCounters.snapshotCoveredArrays(with: context)
                    }
                }
            }

            // 10 tasks doing snapshots
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<20 {
                        _ = SanCovCounters.snapshot()
                    }
                }
            }
        }
    }

    @Test("Concurrent corpus and coverage operations", .timeLimit(.minutes(1)))
    func concurrentCorpusAndCoverage() async {
        let corpus = Corpus<Int>(schemaVersion: "1.0.0")

        await withTaskGroup(of: Void.self) { group in
            // Tasks that measure coverage and add to corpus
            for i in 0..<30 {
                group.addTask {
                    for j in 0..<10 {
                        // Measure coverage with context
                        guard let context = SanCovCounters.beginMeasurement() else { continue }
                        var x = i * j
                        for k in 0..<20 { x += k }
                        _ = x

                        // Create signature from context
                        let signature: CoverageSignature
                        if let coverage = SanCovCounters.snapshotCoveredArrays(with: context) {
                            signature = CoverageSignature(sparse: coverage)
                        } else {
                            signature = makeSignature(indices: [i, j])
                        }
                        SanCovCounters.endMeasurement(context)

                        // Add to corpus
                        await corpus.add(input: i * 100 + j, signature: signature)
                    }
                }
            }

            // Tasks that read from corpus
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<20 {
                        _ = await corpus.snapshot()
                    }
                }
            }
        }
    }
}
