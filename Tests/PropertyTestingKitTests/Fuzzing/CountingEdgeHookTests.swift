//
//  CountingEdgeHookTests.swift
//  PropertyTestingKit
//
//  Tests for countingEdgeHook — the 8-bit saturating counter hook.
//  Calls the hook directly with arbitrary guard values rather than
//  running instrumented code.
//

import Testing
import SanCovHooks
@testable import PropertyTestingKit

@Suite("Counting Edge Hook", .serialized)
struct CountingEdgeHookTests {

    @Test("First hit sets counter to 1")
    func firstHitSetsOne() {
        let ctx = sancov_begin_measurement()!
        defer { sancov_end_measurement(ctx) }

        var guardVal: UInt32 = 0
        countingEdgeHook(&guardVal)

        let map = ctx.pointee.coverage_map!
        #expect(map[0] == 1)
    }

    @Test("Subsequent hits increment the counter")
    func subsequentHitsIncrement() {
        let ctx = sancov_begin_measurement()!
        defer { sancov_end_measurement(ctx) }

        var guardVal: UInt32 = 0
        for _ in 0..<10 {
            countingEdgeHook(&guardVal)
        }

        let map = ctx.pointee.coverage_map!
        #expect(map[0] == 10)
    }

    @Test("Counter saturates at 255")
    func saturatesAt255() {
        let ctx = sancov_begin_measurement()!
        defer { sancov_end_measurement(ctx) }

        var guardVal: UInt32 = 0
        for _ in 0..<300 {
            countingEdgeHook(&guardVal)
        }

        let map = ctx.pointee.coverage_map!
        #expect(map[0] == 255)
    }

    @Test("Different guards track independently")
    func differentGuardsIndependent() {
        let ctx = sancov_begin_measurement()!
        defer { sancov_end_measurement(ctx) }

        var guard0: UInt32 = 0
        var guard1: UInt32 = 1

        for _ in 0..<5 {
            countingEdgeHook(&guard0)
        }
        for _ in 0..<20 {
            countingEdgeHook(&guard1)
        }

        let map = ctx.pointee.coverage_map!
        #expect(map[0] == 5)
        #expect(map[1] == 20)
    }

    @Test("First hit records edge index in covered_indices")
    func firstHitRecordsIndex() {
        let ctx = sancov_begin_measurement()!
        defer { sancov_end_measurement(ctx) }

        var guard3: UInt32 = 3
        var guard7: UInt32 = 7

        countingEdgeHook(&guard3)
        countingEdgeHook(&guard7)
        // Subsequent hits should NOT add more indices
        countingEdgeHook(&guard3)
        countingEdgeHook(&guard3)

        #expect(ctx.pointee.covered_count == 2)
        #expect(ctx.pointee.covered_indices[0] == 3)
        #expect(ctx.pointee.covered_indices[1] == 7)
    }

    @Test("Reset zeroes map values")
    func resetZeroesMap() {
        let ctx = sancov_begin_measurement()!
        defer { sancov_end_measurement(ctx) }

        var guardVal: UInt32 = 0
        for _ in 0..<50 {
            countingEdgeHook(&guardVal)
        }

        #expect(ctx.pointee.coverage_map![0] == 50)

        sancov_reset_coverage(ctx)

        // Map value should be zeroed by reset
        #expect(ctx.pointee.coverage_map![0] == 0)
    }

    @Test("Counters accumulate fresh after reset")
    func freshAfterReset() {
        let ctx = sancov_begin_measurement()!
        defer { sancov_end_measurement(ctx) }

        var guardVal: UInt32 = 0
        for _ in 0..<10 {
            countingEdgeHook(&guardVal)
        }
        #expect(ctx.pointee.coverage_map![0] == 10)

        sancov_reset_coverage(ctx)

        for _ in 0..<100 {
            countingEdgeHook(&guardVal)
        }
        // Map should reflect only the second batch
        #expect(ctx.pointee.coverage_map![0] == 100)
    }

    @Test("Binary hook only records 1 regardless of hits")
    func binaryHookComparison() {
        let ctx = sancov_begin_measurement()!
        defer { sancov_end_measurement(ctx) }

        var guardVal: UInt32 = 0
        for _ in 0..<50 {
            defaultEdgeHook(&guardVal)
        }

        let map = ctx.pointee.coverage_map!
        #expect(map[0] == 1, "Binary hook should stay at 1 regardless of hit count")
    }
}
