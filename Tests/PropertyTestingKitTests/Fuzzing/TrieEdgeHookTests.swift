//
//  TrieEdgeHookTests.swift
//  PropertyTestingKit
//
//  Tests for the trie-based edge hook.
//  Calls the hook directly with arbitrary guard values.
//

import Testing
import SanCovHooks
@testable import PropertyTestingKit

@Suite("Trie Edge Hook", .serialized)
struct TrieEdgeHookTests {

    /// Helper: create a measurement context with a trie attached.
    private func beginTrieMeasurement() -> (UnsafeMutablePointer<SanCovMeasurementContext>, PathTrie) {
        let ctx = sancov_begin_measurement()!
        let trie = PathTrie()
        trie.attach(to: ctx)
        return (ctx, trie)
    }

    // MARK: - Basic Path Tracking

    @Test("First path is always unique")
    func firstPathUnique() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)

        #expect(trie.isUniquePath)
    }

    @Test("Same path twice is not unique")
    func samePathNotUnique() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1

        // First run: 0 → 1
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        #expect(trie.isUniquePath)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // Second run: same path 0 → 1
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        #expect(!trie.isUniquePath)
    }

    @Test("Different path is unique")
    func differentPathUnique() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1
        var g2: UInt32 = 2

        // First run: 0 → 1
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // Second run: 0 → 2 (different second edge)
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g2)
        #expect(trie.isUniquePath)
    }

    @Test("Reversed path is unique")
    func reversedPathUnique() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1

        // First run: 0 → 1
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // Second run: 1 → 0
        sancov_record_edge_trie(&g1)
        sancov_record_edge_trie(&g0)
        #expect(trie.isUniquePath)
    }

    // MARK: - Length Sensitivity

    @Test("Prefix of existing path is unique")
    func prefixIsUnique() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1
        var g2: UInt32 = 2

        // First run: 0 → 1 → 2
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        sancov_record_edge_trie(&g2)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // Second run: 0 → 1 (prefix)
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        #expect(trie.isUniquePath, "Prefix of existing path should be unique")
    }

    @Test("Extension of existing path is unique")
    func extensionIsUnique() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1
        var g2: UInt32 = 2

        // First run: 0 → 1
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // Second run: 0 → 1 → 2 (extension — novel because edge 2 added new node)
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        sancov_record_edge_trie(&g2)
        #expect(trie.isUniquePath, "Extension of existing path should be unique")
    }

    // MARK: - Multiple Paths

    @Test("Many unique paths then duplicate")
    func manyPathsThenDuplicate() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        // Store 5 different paths
        for i: UInt32 in 0..<5 {
            var g0: UInt32 = 0
            var gi: UInt32 = i + 1
            sancov_record_edge_trie(&g0)
            sancov_record_edge_trie(&gi)
            #expect(trie.isUniquePath)
            trie.markTerminal()
            trie.reset()
            sancov_reset_coverage(ctx)
        }

        // Replay path 0 → 3 (already stored)
        var g0: UInt32 = 0
        var g3: UInt32 = 3
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g3)
        #expect(!trie.isUniquePath, "Previously stored path should not be unique")
    }

    // MARK: - Novel Flag

    @Test("Novel flag set on first unseen edge")
    func novelFlagOnNewEdge() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1

        // First run: 0 → 1
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // Second run: 0 → 1 is terminal, so NOT unique
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        #expect(!trie.isUniquePath)
        trie.reset()
        sancov_reset_coverage(ctx)

        // Third run: 0 → 1 → new edge 5 — novel flag should be set
        var g5: UInt32 = 5
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        sancov_record_edge_trie(&g5)
        #expect(trie.isUniquePath, "Path with new edge should be unique via novel flag")
    }

    // MARK: - Reset

    @Test("Reset clears state for next iteration")
    func resetClearsState() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1

        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // After reset, a completely new path should be unique
        var g9: UInt32 = 9
        sancov_record_edge_trie(&g9)
        #expect(trie.isUniquePath)
    }

    // MARK: - Loop Immunity

    @Test("Repeated edge hits don't advance trie")
    func repeatedEdgeIgnored() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1

        // First run: 0 → 1, with edge 0 hit multiple times (loop)
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g0) // repeat — should be ignored by trie
        sancov_record_edge_trie(&g0) // repeat
        sancov_record_edge_trie(&g1)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // Second run: 0 → 1, without repeats — should be same trie path
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)
        #expect(!trie.isUniquePath, "Repeated edges should not create different paths")
    }

    @Test("Different loop counts produce same path")
    func loopCountsIdentical() {
        let (ctx, trie) = beginTrieMeasurement()
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1
        var g2: UInt32 = 2

        // First run: 0 → 1 (hit 5 times) → 2
        sancov_record_edge_trie(&g0)
        for _ in 0..<5 { sancov_record_edge_trie(&g1) }
        sancov_record_edge_trie(&g2)
        trie.markTerminal()
        trie.reset()
        sancov_reset_coverage(ctx)

        // Second run: 0 → 1 (hit 100 times) → 2 — same first-hit sequence
        sancov_record_edge_trie(&g0)
        for _ in 0..<100 { sancov_record_edge_trie(&g1) }
        sancov_record_edge_trie(&g2)
        #expect(!trie.isUniquePath, "Different iteration counts should produce same path")
    }

    // MARK: - Also Records Coverage

    @Test("Trie hook also records binary coverage")
    func alsoRecordsCoverage() {
        let (ctx, trie) = beginTrieMeasurement()
        _ = trie
        defer { sancov_end_measurement(ctx) }

        var g0: UInt32 = 0
        var g1: UInt32 = 1
        sancov_record_edge_trie(&g0)
        sancov_record_edge_trie(&g1)

        let map = ctx.pointee.coverage_map!
        #expect(map[0] == 1)
        #expect(map[1] == 1)
    }

    // MARK: - Empty Path

    @Test("Empty path is unique on first run")
    func emptyPathFirstRun() {
        let trie = PathTrie()
        #expect(trie.isUniquePath)
    }

    @Test("Empty path is not unique after marking terminal")
    func emptyPathAfterTerminal() {
        let trie = PathTrie()
        trie.markTerminal()
        trie.reset()
        #expect(!trie.isUniquePath)
    }
}
