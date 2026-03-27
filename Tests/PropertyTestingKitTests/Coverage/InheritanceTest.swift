import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

/// Tests for coverage inheritance — child tasks writing edges to their
/// parent engine's measurement context via task-local propagation.
@Suite("Coverage Inheritance")
struct InheritanceTest {

    // MARK: - Test-only functions with distinct branches

    /// Only called inside child tasks. @inline(never) prevents inlining
    /// so its edges are distinct from the caller.
    @inline(never)
    static func childOnlyWork(_ x: Int) -> Int {
        if x > 0 { return x * 2 }
        else { return x + 1 }
    }

    @inline(never)
    static func branchA() -> Int { return 111 }

    @inline(never)
    static func branchB() -> Int { return 222 }

    // MARK: - Core inheritance

    @Test("Child task edges from TaskGroup are captured")
    func taskGroupChildEdgesCaptured() async throws {
        // Baseline: call childOnlyWork directly to learn its edge indices
        let refCtx = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(refCtx)
        let _ = Self.childOnlyWork(42)
        let childWorkEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: refCtx)).indices)
        SanCovCounters.endMeasurement(refCtx)
        #expect(!childWorkEdges.isEmpty, "childOnlyWork must produce edges when called directly")

        // WITH inheritance
        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx)
        let ctxBits = UInt(bitPattern: ctx.rawContext)
        await CoverageInheritance.$context.withValue(ctxBits) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: ctxBits)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { let _ = Self.childOnlyWork(42) }
            }
        }
        sancov_rebuild_covered_indices_from_map(ctx.rawContext)
        let withEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: ctx)).indices)
        SanCovCounters.endMeasurement(ctx)

        // WITHOUT inheritance
        let ctx2 = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx2)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { let _ = Self.childOnlyWork(42) }
        }
        let withoutEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: ctx2)).indices)
        SanCovCounters.endMeasurement(ctx2)

        // childOnlyWork edges must appear WITH inheritance but NOT without
        let found = childWorkEdges.intersection(withEdges)
        let leaked = childWorkEdges.intersection(withoutEdges)
        #expect(found == childWorkEdges,
                "All childOnlyWork edges must be captured with inheritance. Missing: \(childWorkEdges.subtracting(found))")
        #expect(leaked.isEmpty,
                "Without inheritance, childOnlyWork edges must NOT appear in engine context. Leaked: \(leaked)")
    }

    // MARK: - Task {} (unstructured but inheriting)

    @Test("Task {} inherits coverage context")
    func unstructuredTaskInherits() async throws {
        let refCtx = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(refCtx)
        let _ = Self.childOnlyWork(42)
        let childWorkEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: refCtx)).indices)
        SanCovCounters.endMeasurement(refCtx)

        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx)
        let ctxBits = UInt(bitPattern: ctx.rawContext)
        await CoverageInheritance.$context.withValue(ctxBits) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: ctxBits)
            // Task {} inherits task locals (unlike Task.detached)
            let task = Task { let _ = Self.childOnlyWork(42) }
            await task.value
        }
        sancov_rebuild_covered_indices_from_map(ctx.rawContext)
        let edges = Set((try SanCovCounters.snapshotCoveredArrays(with: ctx)).indices)
        SanCovCounters.endMeasurement(ctx)

        let found = childWorkEdges.intersection(edges)
        #expect(found == childWorkEdges,
                "Task {} should inherit context. Missing: \(childWorkEdges.subtracting(found))")
    }

    // MARK: - Task.detached does NOT inherit

    @Test("Task.detached does NOT inherit coverage context")
    func detachedTaskDoesNotInherit() async throws {
        let refCtx = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(refCtx)
        let _ = Self.childOnlyWork(42)
        let childWorkEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: refCtx)).indices)
        SanCovCounters.endMeasurement(refCtx)

        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx)
        let ctxBits = UInt(bitPattern: ctx.rawContext)
        await CoverageInheritance.$context.withValue(ctxBits) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: ctxBits)
            let task = Task.detached { let _ = Self.childOnlyWork(42) }
            await task.value
        }
        sancov_rebuild_covered_indices_from_map(ctx.rawContext)
        let edges = Set((try SanCovCounters.snapshotCoveredArrays(with: ctx)).indices)
        SanCovCounters.endMeasurement(ctx)

        let leaked = childWorkEdges.intersection(edges)
        #expect(leaked.isEmpty,
                "Task.detached should NOT inherit context. Leaked edges: \(leaked)")
    }

    // MARK: - rebuild_covered_indices correctness

    @Test("sancov_rebuild_covered_indices_from_map produces correct indices")
    func rebuildCoveredIndicesCorrectness() async throws {
        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx)

        // Hit some known edges via direct call on the engine task
        let _ = Self.branchA()
        let _ = Self.branchB()

        // Snapshot via the normal covered_indices path
        let normalSnapshot = try SanCovCounters.snapshotCoveredArrays(with: ctx)

        // Clear covered_indices and rebuild from bitmap
        // (simulate what happens after child task writes)
        sancov_rebuild_covered_indices_from_map(ctx.rawContext)
        let rebuiltSnapshot = try SanCovCounters.snapshotCoveredArrays(with: ctx)

        SanCovCounters.endMeasurement(ctx)

        // Rebuilt indices should be a superset of normal indices
        // (rebuild scans entire bitmap, normal only tracks first-hits)
        let normalSet = Set(normalSnapshot.indices)
        let rebuiltSet = Set(rebuiltSnapshot.indices)

        #expect(normalSet.isSubset(of: rebuiltSet),
                "Rebuilt indices must contain all normally-tracked indices. Missing: \(normalSet.subtracting(rebuiltSet))")
    }

    // MARK: - Parallel engine isolation

    @Test("Parallel engines get independent inherited contexts")
    func parallelEngineIsolation() async throws {
        // Two "engines" each set their own context, run child tasks,
        // and check that edges don't cross-contaminate.

        let ctx1 = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx1)
        let ctx2 = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx2)

        let bits1 = UInt(bitPattern: ctx1.rawContext)
        let bits2 = UInt(bitPattern: ctx2.rawContext)

        // Engine 1: runs branchA in child task
        await CoverageInheritance.$context.withValue(bits1) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: bits1)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { let _ = Self.branchA() }
            }
        }
        sancov_rebuild_covered_indices_from_map(ctx1.rawContext)

        // Engine 2: runs branchB in child task
        await CoverageInheritance.$context.withValue(bits2) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: bits2)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { let _ = Self.branchB() }
            }
        }
        sancov_rebuild_covered_indices_from_map(ctx2.rawContext)

        let edges1 = Set((try SanCovCounters.snapshotCoveredArrays(with: ctx1)).indices)
        let edges2 = Set((try SanCovCounters.snapshotCoveredArrays(with: ctx2)).indices)
        SanCovCounters.endMeasurement(ctx1)
        SanCovCounters.endMeasurement(ctx2)

        // Get reference edges for branchA and branchB
        let refA = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(refA)
        let _ = Self.branchA()
        let branchAEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: refA)).indices)
        SanCovCounters.endMeasurement(refA)

        let refB = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(refB)
        let _ = Self.branchB()
        let branchBEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: refB)).indices)
        SanCovCounters.endMeasurement(refB)

        // Engine 1 should have branchA edges but NOT branchB-only edges
        let aOnly = branchAEdges.subtracting(branchBEdges)
        let bOnly = branchBEdges.subtracting(branchAEdges)

        if !aOnly.isEmpty {
            #expect(!aOnly.intersection(edges1).isEmpty,
                    "Engine 1's context should contain branchA-unique edges")
            #expect(bOnly.intersection(edges1).isEmpty,
                    "Engine 1's context should NOT contain branchB-unique edges. Contaminated: \(bOnly.intersection(edges1))")
        }

        if !bOnly.isEmpty {
            #expect(!bOnly.intersection(edges2).isEmpty,
                    "Engine 2's context should contain branchB-unique edges")
            #expect(aOnly.intersection(edges2).isEmpty,
                    "Engine 2's context should NOT contain branchA-unique edges. Contaminated: \(aOnly.intersection(edges2))")
        }
    }

    // MARK: - FuzzStateMachine integration

    @Test("fuzz() captures child task coverage via newEdge strategy")
    func fuzzIntegrationCapturesChildEdges() async throws {
        // Run a minimal fuzz with a test body that does concurrent work.
        // If inheritance works, the corpus should grow beyond the initial seed
        // because different inputs produce different child task edge sets.
        let result = try await fuzz(
            seeds: [(1,), (2,), (3,)],
            duration: .seconds(5),
            coverageStrategy: .newEdge
        ) { (input: Int) in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Different inputs hit different branches
                    if input % 2 == 0 {
                        let _ = Self.branchA()
                    } else {
                        let _ = Self.branchB()
                    }
                }
            }
        }

        // Without inheritance: engine only sees outer path → ~1 corpus entry
        // With inheritance: engine sees branchA/branchB → 2+ corpus entries
        #expect(result.corpus.entries.count >= 2,
                "fuzz() should find 2+ interesting inputs when child tasks hit different branches. Got \(result.corpus.entries.count)")
    }
}
