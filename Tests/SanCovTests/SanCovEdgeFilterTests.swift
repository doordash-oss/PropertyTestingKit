//
//  SanCovEdgeFilterTests.swift
//  PropertyTestingKit
//
//  Tests for sancov_apply_edge_filter() which disables compiler-generated
//  edges (outlined destroyers, lazy witness table accessors, etc.).
//

import Testing
import SanCovHooks
import Foundation

@Suite("SanCov Edge Filter")
struct SanCovEdgeFilterTests {

    @Test("applyEdgeFilter marks compiler-generated edges")
    func filterMarksCompilerEdges() {
        // Precondition: guards and PCs must be available
        guard sancov_counters_available() else {
            Issue.record("Coverage counters not available — binary not compiled with -sanitize-coverage=edge")
            return
        }
        guard sancov_pcs_available() else {
            Issue.record("PC table not available — binary not compiled with -sanitize-coverage=pc-table")
            return
        }

        let totalEdges = sancov_get_counter_count()
        #expect(totalEdges > 0, "Should have instrumented edges")

        // Apply the filter
        sancov_apply_edge_filter()

        let filteredCount = sancov_get_filtered_count()

        // In a Swift binary compiled with -sanitize-coverage=edge, there should be
        // at least some compiler-generated edges (outlined destroyers, lazy accessors).
        // If this fails, the test binary may not contain any Swift standard library code.
        #expect(filteredCount > 0, "Expected at least some compiler-generated edges to be filtered, got 0 out of \(totalEdges)")

        // Verify the ratio is reasonable — typically 30-65% of edges are compiler-generated
        // (metadata accessors, async resume/yield points, outlined ops, global addressors).
        let ratio = Double(filteredCount) / Double(totalEdges)
        #expect(ratio < 0.75, "Filtered \(filteredCount)/\(totalEdges) (\(Int(ratio * 100))%) — more than 75% seems wrong")
    }

    @Test("filtered edges are not recorded in coverage")
    func filteredEdgesNotRecorded() {
        guard sancov_counters_available() else {
            Issue.record("Coverage counters not available")
            return
        }
        guard sancov_pcs_available() else {
            Issue.record("PC table not available")
            return
        }

        // Apply filter first
        sancov_apply_edge_filter()
        let filteredCount = sancov_get_filtered_count()
        guard filteredCount > 0 else {
            // Nothing was filtered, can't test this
            return
        }

        // Begin a measurement context
        guard let context = sancov_begin_measurement() else {
            Issue.record("Failed to begin measurement")
            return
        }
        defer { sancov_end_measurement(context) }

        // Exercise some code that will trigger coverage
        exerciseCode()

        // Get the covered indices
        let coveredCount = sancov_get_covered_count_with_context(context)
        guard coveredCount > 0 else {
            // No coverage at all — can't verify
            return
        }

        var outCount: Int = 0
        guard let indices = sancov_get_covered_indices(context, &outCount) else {
            return
        }

        // Verify none of the covered edges have the SANCOV_GUARD_SKIP sentinel
        // We can't read the guard values directly from Swift, but we know that
        // any edge that was filtered would have guard = UINT32_MAX, which means
        // it can't pass the `*guard < g_guard_count` check, so it should never
        // appear in the covered indices.
        let totalEdges = sancov_get_counter_count()
        for i in 0..<outCount {
            let edgeIndex = indices[i]
            #expect(edgeIndex < UInt32(totalEdges),
                    "Covered edge index \(edgeIndex) should be less than total edge count \(totalEdges)")
        }
    }

    @Test("filter is idempotent")
    func filterIsIdempotent() {
        guard sancov_counters_available(), sancov_pcs_available() else {
            return
        }

        sancov_apply_edge_filter()
        let firstCount = sancov_get_filtered_count()

        sancov_apply_edge_filter()
        let secondCount = sancov_get_filtered_count()

        #expect(firstCount == secondCount,
                "Applying filter twice should produce same count: \(firstCount) vs \(secondCount)")
    }
}

// MARK: - Helpers

/// Exercise various code paths to generate coverage.
@inline(never)
private func exerciseCode() {
    // Array operations trigger outlined destroyers and lazy witness table accessors
    var array = [1, 2, 3, 4, 5]
    array.append(6)
    _ = array.map { $0 * 2 }
    _ = array.filter { $0 > 3 }
    _ = array.reduce(0, +)

    // String operations
    let strings = ["hello", "world", "test"]
    _ = strings.joined(separator: ", ")

    // Dictionary operations
    var dict: [String: Int] = [:]
    dict["a"] = 1
    dict["b"] = 2
    _ = dict.count
}
