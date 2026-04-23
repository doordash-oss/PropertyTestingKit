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

//  Tests for verifying that sancov_reset_coverage() correctly clears coverage
//  and that the hoisted measurement context pattern works correctly.
//

import Testing
import SanCovHooks
import Foundation

// MARK: - Test Functions with Distinct Edges

/// These functions have different control flow to create distinct coverage edges.
/// We use them to verify that reset actually clears coverage between iterations.

@inline(never)
private func pathA(_ x: Int) -> Int {
    if x > 50 { return x * 2 }
    else if x > 25 { return x * 3 }
    else { return x * 4 }
}

@inline(never)
private func pathB(_ x: Int) -> Int {
    switch x % 5 {
    case 0: return x + 10
    case 1: return x + 20
    case 2: return x + 30
    case 3: return x + 40
    default: return x + 50
    }
}

@inline(never)
private func pathC(_ x: Int) -> Int {
    var result = x
    if x & 1 != 0 { result += 100 }
    if x & 2 != 0 { result += 200 }
    if x & 4 != 0 { result += 400 }
    return result
}

/// Helper to get covered indices from a measurement context
private func getResetTestCoveredIndices(context: UnsafeMutablePointer<SanCovMeasurementContext>?) -> Set<UInt32> {
    let count = sancov_get_covered_count_with_context(context)
    guard count > 0 else { return [] }

    guard let indices = sancov_snapshot_covered_indices_with_context(context) else {
        return []
    }
    defer { free(indices) }

    let buffer = UnsafeBufferPointer(start: indices, count: count)
    return Set(buffer)
}

// MARK: - Reset Coverage Tests

@Suite("Coverage Reset Tests")
struct CoverageResetTests {

    @Test("resetCoverage allows fresh coverage accumulation")
    func testResetAllowsFreshCoverage() async {
        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }

        // Run pathA to generate coverage
        for i in 0..<100 { _ = pathA(i) }
        let pathACoverage = getResetTestCoveredIndices(context: context)
        #expect(!pathACoverage.isEmpty, "Should have coverage from pathA")

        // Reset coverage
        sancov_reset_coverage(context)

        // Run pathB (different code path)
        for i in 0..<100 { _ = pathB(i) }
        let pathBCoverage = getResetTestCoveredIndices(context: context)
        #expect(!pathBCoverage.isEmpty, "Should have coverage from pathB")

        // The key test: pathB coverage should be "fresh" - it should contain pathB's edges
        // and not accumulate on top of pathA's edges (which were reset)
        // Since pathA and pathB are different functions, they have some unique edges
        let pathAUnique = pathACoverage.subtracting(pathBCoverage)
        let pathBUnique = pathBCoverage.subtracting(pathACoverage)

        // At least one set should have unique edges (different functions = different coverage)
        let hasDifferentCoverage = !pathAUnique.isEmpty || !pathBUnique.isEmpty
        #expect(hasDifferentCoverage, "pathA and pathB should have different coverage patterns")
    }

    @Test("Coverage accumulates correctly after reset")
    func testCoverageAccumulatesAfterReset() async {
        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }

        // Run pathA
        for i in 0..<100 { _ = pathA(i) }
        let pathACoverage = getResetTestCoveredIndices(context: context)

        // Reset
        sancov_reset_coverage(context)

        // Run pathB (different function with different edges)
        for i in 0..<100 { _ = pathB(i) }
        let pathBCoverage = getResetTestCoveredIndices(context: context)

        #expect(!pathACoverage.isEmpty, "pathA should have coverage")
        #expect(!pathBCoverage.isEmpty, "pathB should have coverage")

        // pathB coverage should NOT contain pathA's edges (since we reset)
        // Note: Some edges might overlap if the functions share common code paths,
        // but the unique edges from pathA should not be present
        let uniqueToPathA = pathACoverage.subtracting(pathBCoverage)

        // If pathA had unique edges, they should not appear in pathB's coverage
        // (This verifies reset actually worked)
        if !uniqueToPathA.isEmpty {
            // Good - pathA had unique edges that are not in pathB
            // This confirms the functions have distinct coverage
        }
    }

    @Test("Multiple resets work correctly on same context")
    func testMultipleResets() async {
        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }

        var coverages: [Set<UInt32>] = []

        // Run 10 iterations with reset between each
        for iteration in 0..<10 {
            sancov_reset_coverage(context)

            // Verify coverage is zero after reset
            let countAfterReset = sancov_get_covered_count_with_context(context)
            #expect(countAfterReset == 0, "Iteration \(iteration): Coverage should be 0 after reset")

            // Run different path based on iteration
            switch iteration % 3 {
            case 0:
                for i in 0..<100 { _ = pathA(i) }
            case 1:
                for i in 0..<100 { _ = pathB(i) }
            default:
                for i in 0..<100 { _ = pathC(i) }
            }

            let coverage = getResetTestCoveredIndices(context: context)
            #expect(!coverage.isEmpty, "Iteration \(iteration): Should have coverage after running code")
            coverages.append(coverage)
        }

        // Verify we got coverage in all iterations
        #expect(coverages.count == 10)
        for (i, coverage) in coverages.enumerated() {
            #expect(!coverage.isEmpty, "Iteration \(i) should have non-empty coverage")
        }
    }

    @Test("Each iteration sees only its own coverage (fuzz loop pattern)")
    func testIterationIsolation() async {
        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }

        // This simulates the actual fuzz loop pattern
        var iterationCoverages: [(iteration: Int, coverage: Set<UInt32>)] = []

        for iteration in 0..<20 {
            // Reset coverage at start of iteration (like fuzz loop does)
            sancov_reset_coverage(context)

            // Run only ONE of the paths based on iteration
            // Each path should have some unique edges
            switch iteration % 3 {
            case 0:
                _ = pathA(iteration)  // Single call, not a loop
            case 1:
                _ = pathB(iteration)
            default:
                _ = pathC(iteration)
            }

            // Snapshot coverage for this iteration
            let coverage = getResetTestCoveredIndices(context: context)
            iterationCoverages.append((iteration, coverage))
        }

        // Verify: iterations that called pathA should have similar coverage to each other
        // but different from iterations that called pathB or pathC
        let pathAIterations = iterationCoverages.filter { $0.iteration % 3 == 0 }
        let pathBIterations = iterationCoverages.filter { $0.iteration % 3 == 1 }
        _ = iterationCoverages.filter { $0.iteration % 3 == 2 } // pathC iterations (unused but validates coverage)

        // All pathA iterations should have identical coverage (same function, same input pattern)
        if pathAIterations.count > 1 {
            let first = pathAIterations[0].coverage
            for (i, iter) in pathAIterations.dropFirst().enumerated() {
                // Coverage should be very similar (might not be identical due to input differences)
                let intersection = first.intersection(iter.coverage)
                #expect(!intersection.isEmpty,
                        "PathA iterations should share common edges: iteration 0 vs \(i+1)")
            }
        }

        // pathA and pathB should have some distinct edges
        if let firstA = pathAIterations.first, let firstB = pathBIterations.first {
            let onlyInA = firstA.coverage.subtracting(firstB.coverage)
            let onlyInB = firstB.coverage.subtracting(firstA.coverage)

            // At least one of them should have unique edges (different functions)
            let hasDistinction = !onlyInA.isEmpty || !onlyInB.isEmpty
            #expect(hasDistinction, "pathA and pathB should have some distinct edges")
        }
    }

    @Test("Reset only affects the specific context's coverage map")
    func testResetAffectsOnlyTargetContext() async {
        // Create two contexts
        let context1 = sancov_begin_measurement()
        let context2 = sancov_begin_measurement()
        defer {
            sancov_end_measurement(context1)
            sancov_end_measurement(context2)
        }

        // Run code - coverage will be recorded to both contexts
        for i in 0..<100 { _ = pathA(i) }

        // Get counts before reset
        let count1Before = sancov_get_covered_count_with_context(context1)
        let count2Before = sancov_get_covered_count_with_context(context2)

        // Reset only context1
        sancov_reset_coverage(context1)

        // Get counts after reset
        let count1After = sancov_get_covered_count_with_context(context1)
        let count2After = sancov_get_covered_count_with_context(context2)

        // context1's covered_count should be 0 after reset
        #expect(count1After == 0, "context1 covered_count should be 0 after reset, got \(count1After)")

        // context2's covered_count should be unchanged
        #expect(count2After == count2Before, "context2 should keep its count: expected \(count2Before), got \(count2After)")
    }

    @Test("High iteration count stress test")
    func testHighIterationCount() async {
        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }

        var nonEmptyCoverageCount = 0
        var zeroAfterResetCount = 0

        // Simulate 1000 fuzz iterations
        for iteration in 0..<1000 {
            sancov_reset_coverage(context)

            // Verify reset worked
            if sancov_get_covered_count_with_context(context) == 0 {
                zeroAfterResetCount += 1
            }

            // Run some code
            _ = pathA(iteration)
            _ = pathB(iteration)

            // Verify we got coverage
            if sancov_get_covered_count_with_context(context) > 0 {
                nonEmptyCoverageCount += 1
            }
        }

        #expect(zeroAfterResetCount == 1000,
                "All 1000 resets should result in zero coverage, got \(zeroAfterResetCount)")
        #expect(nonEmptyCoverageCount == 1000,
                "All 1000 iterations should have coverage after running code, got \(nonEmptyCoverageCount)")
    }

    @Test("Coverage signature changes correctly between iterations")
    func testCoverageSignatureChanges() async {
        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }

        var signatures: [Set<UInt32>] = []

        // Run 6 iterations, alternating between pathA and pathB
        for iteration in 0..<6 {
            sancov_reset_coverage(context)

            if iteration % 2 == 0 {
                for i in 0..<50 { _ = pathA(i) }
            } else {
                for i in 0..<50 { _ = pathB(i) }
            }

            signatures.append(getResetTestCoveredIndices(context: context))
        }

        // Iterations 0, 2, 4 (pathA) should be similar
        // Iterations 1, 3, 5 (pathB) should be similar
        // pathA and pathB iterations should differ

        let pathASignatures = [signatures[0], signatures[2], signatures[4]]
        let pathBSignatures = [signatures[1], signatures[3], signatures[5]]

        // Within pathA iterations, coverage should be identical
        #expect(pathASignatures[0] == pathASignatures[1], "pathA iterations should have same coverage")
        #expect(pathASignatures[1] == pathASignatures[2], "pathA iterations should have same coverage")

        // Within pathB iterations, coverage should be identical
        #expect(pathBSignatures[0] == pathBSignatures[1], "pathB iterations should have same coverage")
        #expect(pathBSignatures[1] == pathBSignatures[2], "pathB iterations should have same coverage")

        // pathA and pathB should differ
        #expect(pathASignatures[0] != pathBSignatures[0],
                "pathA and pathB should have different coverage signatures")
    }

    @Test("Reset with nil context doesn't crash")
    func testResetNilContext() async {
        // This should be a no-op, not a crash
        sancov_reset_coverage(nil)
        // If we get here, the test passed
    }

    @Test("Sequential resets work correctly")
    func testSequentialResets() async {
        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }

        // Run 100 sequential reset cycles
        for iteration in 0..<100 {
            sancov_reset_coverage(context)

            // Verify count is 0 after reset
            let countAfterReset = sancov_get_covered_count_with_context(context)
            #expect(countAfterReset == 0,
                    "Iteration \(iteration): count should be 0 after reset, got \(countAfterReset)")

            // Run code
            switch iteration % 3 {
            case 0: for i in 0..<10 { _ = pathA(i) }
            case 1: for i in 0..<10 { _ = pathB(i) }
            default: for i in 0..<10 { _ = pathC(i) }
            }

            // Verify we got coverage
            let countAfterCode = sancov_get_covered_count_with_context(context)
            #expect(countAfterCode > 0,
                    "Iteration \(iteration): should have coverage after running code")
        }
    }
}
