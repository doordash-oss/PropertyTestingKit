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
        let ctxBits = ctx.inheritanceHandle
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
        let ctxBits = ctx.inheritanceHandle
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
        let ctxBits = ctx.inheritanceHandle
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

        FileHandle.standardError.write("[TEST] ctx1=\(ctx1.rawContext) ctx2=\(ctx2.rawContext)\n".data(using: .utf8) ?? Data())

        let bits1 = ctx1.inheritanceHandle
        let bits2 = ctx2.inheritanceHandle

        func logTid(_ tag: String) {
            var t: UInt64 = 0
            pthread_threadid_np(nil, &t)
            FileHandle.standardError.write("[TEST] \(tag) tid=\(t)\n".data(using: .utf8) ?? Data())
        }

        // Engine 1: runs branchA in child task
        logTid("before-engine1")
        await CoverageInheritance.$context.withValue(bits1) {
            logTid("inside-engine1-withValue")
            CoverageInheritance.captureKeyIfNeeded(contextBits: bits1)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var t: UInt64 = 0
                    pthread_threadid_np(nil, &t)
                    FileHandle.standardError.write("[TEST] engine1-child tid=\(t)\n".data(using: .utf8) ?? Data())
                    let _ = Self.branchA()
                }
            }
        }
        sancov_rebuild_covered_indices_from_map(ctx1.rawContext)
        logTid("after-engine1")

        // Engine 2: runs branchB in child task
        logTid("before-engine2")
        await CoverageInheritance.$context.withValue(bits2) {
            logTid("inside-engine2-withValue")
            CoverageInheritance.captureKeyIfNeeded(contextBits: bits2)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var t: UInt64 = 0
                    pthread_threadid_np(nil, &t)
                    let task = sancov_get_current_task()
                    let taskHex = String(format: "0x%lx", Int(bitPattern: task))
                    FileHandle.standardError.write("[TEST] engine2-child tid=\(t) task=\(taskHex)\n".data(using: .utf8) ?? Data())
                    let _ = Self.branchB()
                }
            }
        }
        sancov_rebuild_covered_indices_from_map(ctx2.rawContext)
        logTid("after-engine2")

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
            // Diagnostic: when this expectation fails, dump where branchB's
            // edges actually went so we can identify cross-suite contamination.
            let bInEdges1 = bOnly.intersection(edges1)
            let bInEdges2 = bOnly.intersection(edges2)
            let lostB = bOnly.subtracting(edges1).subtracting(edges2)
            if bInEdges2.isEmpty {
                let hookPtr = dlsym(dlopen(nil, 0), "swift_task_enqueueGlobal_hook")!
                    .assumingMemoryBound(to: UnsafeRawPointer?.self)
                let hookInstalled = hookPtr.pointee != nil
                print("[parallelEngineIsolation FAILURE DIAG]")
                print("  bOnly count=\(bOnly.count): \(Array(bOnly).sorted())")
                print("  bOnly ∩ edges1 (leaked into engine 1): \(Array(bInEdges1).sorted())")
                print("  bOnly ∩ edges2 (correct): \(Array(bInEdges2).sorted())")
                print("  bOnly NOT in either (leaked to a third place): \(Array(lostB).sorted())")
                print("  edges1 count=\(edges1.count) edges2 count=\(edges2.count)")
                print("  scheduler hook installed at end of test: \(hookInstalled)")
                // Symbolicate the lost edges to identify what they are
                for edgeIdx in lostB.sorted() {
                    var loc = SanCovSourceLocation()
                    if sancov_get_source_location(Int(edgeIdx), &loc) {
                        let sym = loc.function_name.flatMap { String(cString: $0) } ?? "?"
                        let file = loc.filename.flatMap { String(cString: $0) } ?? "?"
                        print("  edge \(edgeIdx): pc=0x\(String(loc.pc, radix: 16)) sym=\(sym) file=\(file)")
                    }
                }
                // Also symbolicate edges1 and edges2 contents
                print("  edges1 contents:")
                for edgeIdx in edges1.sorted() {
                    var loc = SanCovSourceLocation()
                    if sancov_get_source_location(Int(edgeIdx), &loc) {
                        let sym = loc.function_name.flatMap { String(cString: $0) } ?? "?"
                        print("    \(edgeIdx): \(sym)")
                    }
                }
                print("  edges2 contents:")
                for edgeIdx in edges2.sorted() {
                    var loc = SanCovSourceLocation()
                    if sancov_get_source_location(Int(edgeIdx), &loc) {
                        let sym = loc.function_name.flatMap { String(cString: $0) } ?? "?"
                        print("    \(edgeIdx): \(sym)")
                    }
                }
                print("  branchAEdges symbolicated:")
                for edgeIdx in branchAEdges.sorted() {
                    var loc = SanCovSourceLocation()
                    if sancov_get_source_location(Int(edgeIdx), &loc) {
                        let sym = loc.function_name.flatMap { String(cString: $0) } ?? "?"
                        print("    \(edgeIdx): \(sym)")
                    }
                }
                print("  branchBEdges symbolicated:")
                for edgeIdx in branchBEdges.sorted() {
                    var loc = SanCovSourceLocation()
                    if sancov_get_source_location(Int(edgeIdx), &loc) {
                        let sym = loc.function_name.flatMap { String(cString: $0) } ?? "?"
                        print("    \(edgeIdx): \(sym)")
                    }
                }
            }
            #expect(!bOnly.intersection(edges2).isEmpty,
                    "Engine 2's context should contain branchB-unique edges")
            #expect(aOnly.intersection(edges2).isEmpty,
                    "Engine 2's context should NOT contain branchA-unique edges. Contaminated: \(aOnly.intersection(edges2))")
        }
    }

    // MARK: - FuzzStateMachine integration

    @Test("fuzz() captures child task coverage via newEdge strategy")
    func fuzzIntegrationCapturesChildEdges() async throws {
        // Run a bounded fuzz (deterministic iteration count via the test clock,
        // single engine) with a test body that does concurrent work. Force a fresh
        // fuzz with `.refuzzReplace` so we actually exercise inheritance rather than
        // regression-replaying a saved corpus. If inheritance works, the corpus grows
        // beyond the initial seed because different inputs produce different child
        // task edge sets.
        let result = try await fuzzWithMaxIterations(
            maxIterations: 100,
            seeds: [(1,), (2,), (3,)],
            persistence: .ephemeral,
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

    // MARK: - Parallel engine isolation, aggressive stress

    /// Runs many concurrent engine pairs simultaneously to maximise the chance
    /// of triggering routing-hook races. Each pair sets up its own context
    /// pair, runs branchA/branchB in child tasks under inheritance, and
    /// asserts isolation. This is the aggressive in-process counterpart to
    /// `parallelEngineIsolation` — it doesn't rely on Swift Testing's
    /// inter-test parallelism to expose the race.
    @Test("Parallel engines isolation under heavy concurrent load")
    func parallelEngineIsolationStress() async throws {
        var c0 = SanCovRouteCounters()
        sancov_read_route_counters(&c0)

        // Reference edges for branchA / branchB
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

        let aOnly = branchAEdges.subtracting(branchBEdges)
        let bOnly = branchBEdges.subtracting(branchAEdges)

        // Run N pairs concurrently × M iterations per pair. Both knobs
        // increase the chance of triggering routing-hook races.
        let parallelism = 32
        let iterationsPerPair = 8
        struct Failure: Error { let message: String }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for pairIdx in 0..<parallelism {
                group.addTask {
                    for iter in 0..<iterationsPerPair {
                        let ctx1 = SanCovCounters.beginMeasurement()
                        SanCovCounters.resetCoverage(ctx1)
                        let ctx2 = SanCovCounters.beginMeasurement()
                        SanCovCounters.resetCoverage(ctx2)
                        defer {
                            SanCovCounters.endMeasurement(ctx1)
                            SanCovCounters.endMeasurement(ctx2)
                        }

                        let bits1 = ctx1.inheritanceHandle
                        let bits2 = ctx2.inheritanceHandle

                        await CoverageInheritance.$context.withValue(bits1) {
                            CoverageInheritance.captureKeyIfNeeded(contextBits: bits1)
                            await withTaskGroup(of: Void.self) { g in
                                g.addTask { let _ = Self.branchA() }
                            }
                        }
                        sancov_rebuild_covered_indices_from_map(ctx1.rawContext)

                        await CoverageInheritance.$context.withValue(bits2) {
                            CoverageInheritance.captureKeyIfNeeded(contextBits: bits2)
                            await withTaskGroup(of: Void.self) { g in
                                g.addTask { let _ = Self.branchB() }
                            }
                        }
                        sancov_rebuild_covered_indices_from_map(ctx2.rawContext)

                        let edges1 = Set((try SanCovCounters.snapshotCoveredArrays(with: ctx1)).indices)
                        let edges2 = Set((try SanCovCounters.snapshotCoveredArrays(with: ctx2)).indices)

                        if !aOnly.isEmpty {
                            if aOnly.intersection(edges1).isEmpty {
                                throw Failure(message: "pair=\(pairIdx) iter=\(iter) edges1 missing branchA-unique edges: \(aOnly)")
                            }
                            if !bOnly.intersection(edges1).isEmpty {
                                throw Failure(message: "pair=\(pairIdx) iter=\(iter) edges1 contaminated by branchB-unique edges: \(bOnly.intersection(edges1))")
                            }
                        }
                        if !bOnly.isEmpty {
                            let bIn2 = bOnly.intersection(edges2)
                            if bIn2.isEmpty {
                                let lost = bOnly.subtracting(edges1).subtracting(edges2)
                                throw Failure(message: "pair=\(pairIdx) iter=\(iter) edges2 missing branchB-unique edges. lostToFallback=\(lost) leakedTo1=\(bOnly.intersection(edges1))")
                            }
                            if !aOnly.intersection(edges2).isEmpty {
                                throw Failure(message: "pair=\(pairIdx) iter=\(iter) edges2 contaminated by branchA-unique edges: \(aOnly.intersection(edges2))")
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        var c1 = SanCovRouteCounters()
        sancov_read_route_counters(&c1)
        FileHandle.standardError.write(
            "[STRESS_ROUTING] runtime=\(c1.inherited_runtime - c0.inherited_runtime) manualwalk=\(c1.inherited_manualwalk - c0.inherited_manualwalk) tlsfb_inh=\(c1.tls_fallback_inheritance_active - c0.tls_fallback_inheritance_active) [sync=\(c1.tlsfb_sync_pseudo_task - c0.tlsfb_sync_pseudo_task) noHead=\(c1.tlsfb_real_task_no_head - c0.tlsfb_real_task_no_head) noMatch=\(c1.tlsfb_real_task_no_match - c0.tlsfb_real_task_no_match)] target=\(c1.target_ctx - c0.target_ctx) registry=\(c1.per_task_registry - c0.per_task_registry) cache_inh=\(c1.tls_cache_inheritance_active - c0.tls_cache_inheritance_active)\n"
                .data(using: .utf8) ?? Data())
    }
}
