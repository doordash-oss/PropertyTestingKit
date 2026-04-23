// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//
//  SignatureHashTests.swift
//  PropertyTestingKitTests
//
//  Tests for the SparseCoverage signatureHash function to verify collision resistance.
//

import Testing
@testable import PropertyTestingKit

@Suite("Signature Hash")
struct SignatureHashTests {

    // MARK: - Basic Correctness

    @Test("Identical index sets produce identical hashes")
    func identicalSets() {
        let a = SparseCoverage(indices: [1, 2, 3])
        let b = SparseCoverage(indices: [1, 2, 3])
        #expect(a.signatureHash == b.signatureHash)
    }

    @Test("Order does not affect hash")
    func orderIndependent() {
        let a = SparseCoverage(indices: [1, 2, 3])
        let b = SparseCoverage(indices: [3, 1, 2])
        #expect(a.signatureHash == b.signatureHash)
    }

    @Test("Empty coverage has hash 0")
    func emptyHash() {
        let sparse = SparseCoverage(indices: [])
        #expect(sparse.signatureHash == 0)
    }

    @Test("Single element sets with different indices produce different hashes")
    func singleElementDiffers() {
        let a = SparseCoverage(indices: [0])
        let b = SparseCoverage(indices: [1])
        #expect(a.signatureHash != b.signatureHash)
    }

    @Test("Different counts with same XOR produce different hashes")
    func countDisambiguates() {
        // Indices {1, 2} and {3} might have same XOR of index*prime,
        // but different counts should differentiate them
        let a = SparseCoverage(indices: [1, 2])
        let b = SparseCoverage(indices: [3])
        #expect(a.signatureHash != b.signatureHash)
    }

    @Test("Subset and superset produce different hashes")
    func subsetDiffers() {
        let a = SparseCoverage(indices: [1, 2, 3])
        let b = SparseCoverage(indices: [1, 2])
        #expect(a.signatureHash != b.signatureHash)
    }

    // MARK: - Adjacent Index Collision Tests

    @Test("Single adjacent indices never collide for all pairs 0..<10000")
    func singleAdjacentNeverCollide() {
        // Single-element sets should never collide since hash = index * prime ^ count * prime
        var collisions = 0
        for i in UInt32(0)..<10000 {
            let a = SparseCoverage(indices: [i])
            let b = SparseCoverage(indices: [i + 1])
            if a.signatureHash == b.signatureHash {
                collisions += 1
            }
        }
        #expect(collisions == 0, "Single-element adjacent index sets should never collide")
    }

    @Test("Adjacent index swap in 4-element sets: collision rate")
    func adjacentSwapCollisionRate() {
        // This is the exact pattern that caused the realistic coverage gap test to fail:
        // {A, X, C, D} vs {A, X+1, C, D} where only one index differs by 1
        var collisions = 0
        let trials = 10000

        for base in UInt32(0)..<UInt32(trials) {
            // Create two sets that differ by one adjacent index
            let shared: [UInt32] = [base, base + 100, base + 200]
            let a = SparseCoverage(indices: shared + [base + 50])
            let b = SparseCoverage(indices: shared + [base + 51])
            if a.signatureHash == b.signatureHash {
                collisions += 1
            }
        }

        // With a good hash, collision rate should be near 0 out of 10K trials
        // XOR-based hash has a known weakness: if (X * prime) XOR ((X+1) * prime)
        // equals zero, then swapping X for X+1 doesn't change the hash.
        // This can't happen with multiplicative hashing (a*prime differs from (a+1)*prime),
        // so collisions here indicate a structural issue.
        #expect(collisions == 0,
                "Adjacent index swap should not collide: \(collisions)/\(trials) collided")
    }

    @Test("Reproduces the exact collision from edge indices 2120 vs 2121")
    func exactCollisionReproduction() {
        // The exact sets that collided in the coverage gap test
        let a = SparseCoverage(indices: [2118, 2120, 2132, 2133])
        let b = SparseCoverage(indices: [2118, 2121, 2132, 2133])

        // These SHOULD have different hashes (different code paths)
        // If they collide, the signature hash function has a problem
        let hashA = a.signatureHash
        let hashB = b.signatureHash
        #expect(hashA != hashB,
                "Sets differing by one adjacent index should not collide: hash(\(a.indices)) = \(hashA), hash(\(b.indices)) = \(hashB)")
    }

    // MARK: - Statistical Collision Tests

    @Test("Random 4-element sets: collision rate below 0.1%")
    func randomSetCollisionRate() {
        // Generate many random 4-element index sets and measure collision rate
        var rng = FastRNG()
        var hashes = Set<Int>()
        var collisions = 0
        let trials = 100_000

        for _ in 0..<trials {
            let indices: [UInt32] = (0..<4).map { _ in UInt32.random(in: 0..<10000, using: &rng) }
            let sparse = SparseCoverage(indices: indices)
            let hash = sparse.signatureHash
            if hashes.contains(hash) {
                collisions += 1
            }
            hashes.insert(hash)
        }

        let collisionRate = Double(collisions) / Double(trials) * 100
        // Birthday bound for 100K items in 2^64 space is essentially 0
        // Even with imperfect hashing, should be well under 0.1%
        #expect(collisionRate < 0.1,
                "Collision rate \(String(format: "%.4f", collisionRate))% exceeds 0.1% threshold (\(collisions)/\(trials))")
    }

    @Test("Realistic coverage sets: adjacent-index mutations never collide")
    func realisticAdjacentMutations() {
        // Simulate realistic fuzzing: a base set of ~4-8 edges,
        // with one edge changing to an adjacent index (different branch taken)
        var collisions = 0
        var trials = 0

        for baseSize in 3...8 {
            for baseStart in stride(from: UInt32(0), to: 5000, by: 7) {
                let baseIndices = (0..<UInt32(baseSize)).map { baseStart + $0 * 3 }

                // For each position, swap one index with its neighbor
                for pos in 0..<baseSize {
                    let setA = baseIndices
                    var setB = baseIndices
                    setB[pos] = baseIndices[pos] + 1 // adjacent index

                    let a = SparseCoverage(indices: setA)
                    let b = SparseCoverage(indices: setB)
                    trials += 1
                    if a.signatureHash == b.signatureHash {
                        collisions += 1
                    }
                }
            }
        }

        #expect(collisions == 0,
                "Adjacent-index mutations should never collide: \(collisions)/\(trials) collided")
    }

    // MARK: - C vs Swift Implementation Agreement

    @Test("C and Swift hash agree for empty indices")
    func cSwiftAgreeEmpty() {
        let indices: [UInt32] = []
        let cHash = SanCovCounters.computeSignatureHash(indices: indices)
        let swiftHash = SparseCoverage(indices: indices).signatureHash
        #expect(cHash == swiftHash)
    }

    @Test("C and Swift hash agree for single index")
    func cSwiftAgreeSingle() {
        for i in [UInt32(0), 1, 42, 1000, 2120, 2121, 65535] {
            let cHash = SanCovCounters.computeSignatureHash(indices: [i])
            let swiftHash = SparseCoverage(indices: [i]).signatureHash
            #expect(cHash == swiftHash, "Disagreement for index \(i): C=\(cHash) Swift=\(swiftHash)")
        }
    }

    @Test("C and Swift hash agree for the exact indices from the coverage gap test")
    func cSwiftAgreeExactIndices() {
        let setA: [UInt32] = [2118, 2120, 2132, 2133]
        let setB: [UInt32] = [2118, 2121, 2132, 2133]

        let cA = SanCovCounters.computeSignatureHash(indices: setA)
        let swiftA = SparseCoverage(indices: setA).signatureHash
        #expect(cA == swiftA, "Set A: C=\(cA) Swift=\(swiftA)")

        let cB = SanCovCounters.computeSignatureHash(indices: setB)
        let swiftB = SparseCoverage(indices: setB).signatureHash
        #expect(cB == swiftB, "Set B: C=\(cB) Swift=\(swiftB)")

        // Both implementations should agree that these are different
        #expect(cA != cB, "C should distinguish set A from set B")
        #expect(swiftA != swiftB, "Swift should distinguish set A from set B")
    }

    @Test("C and Swift hash agree across 10000 random index sets")
    func cSwiftAgreeRandom() {
        var rng = FastRNG()
        var disagreements = 0

        for _ in 0..<10_000 {
            let count = Int.random(in: 1...8, using: &rng)
            let indices: [UInt32] = (0..<count).map { _ in UInt32.random(in: 0..<10000, using: &rng) }
            let cHash = SanCovCounters.computeSignatureHash(indices: indices)
            let swiftHash = SparseCoverage(indices: indices).signatureHash
            if cHash != swiftHash {
                disagreements += 1
            }
        }

        #expect(disagreements == 0, "\(disagreements) disagreements between C and Swift hash")
    }

    @Test("C and Swift hash agree for adjacent-index pairs")
    func cSwiftAgreeAdjacent() {
        for base in stride(from: UInt32(0), to: 5000, by: 13) {
            let setA: [UInt32] = [base, base + 50, base + 100, base + 200]
            let setB: [UInt32] = [base, base + 51, base + 100, base + 200]

            let cA = SanCovCounters.computeSignatureHash(indices: setA)
            let swiftA = SparseCoverage(indices: setA).signatureHash
            #expect(cA == swiftA, "Set A at base \(base): C=\(cA) Swift=\(swiftA)")

            let cB = SanCovCounters.computeSignatureHash(indices: setB)
            let swiftB = SparseCoverage(indices: setB).signatureHash
            #expect(cB == swiftB, "Set B at base \(base): C=\(cB) Swift=\(swiftB)")
        }
    }

    // MARK: - Live Coverage Hash Tests

    @Test("Live C hash produces different values for different branch coverage")
    func liveHashDiffersForDifferentBranches() {
        guard SanCovCounters.isAvailable else { return }

        let ctx = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(ctx) }

        SanCovCounters.resetCoverage(ctx)
        exerciseBranchA(42)
        let hash1 = SanCovCounters.computeSignatureHash(context: ctx)

        SanCovCounters.resetCoverage(ctx)
        exerciseBranchB(-42)
        let hash2 = SanCovCounters.computeSignatureHash(context: ctx)

        #expect(hash1 != hash2,
                "Different branches should produce different live hashes: h1=\(hash1) h2=\(hash2)")
    }
}

// MARK: - Test Helper Functions

// These exist solely to create distinct coverage patterns.
// They must be in this file (same compilation unit as tests)
// so they're instrumented with -sanitize-coverage.

@inline(never)
private func exerciseBranchA(_ x: Int) {
    if x >= 0 {
        blackHole(x + 1)
    } else {
        blackHole(x - 1)
    }
}

@inline(never)
private func exerciseBranchB(_ x: Int) {
    if x < 0 {
        blackHole(x * 2)
    } else {
        blackHole(x * 3)
    }
}

@inline(never)
private func blackHole(_ x: Int) {
    // Prevent optimizer from eliminating the branches
    withUnsafePointer(to: x) { _ in }
}
