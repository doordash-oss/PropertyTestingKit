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

//  Phase 1 of the extensibility refactor: the instrumentation/scheduler seam.
//  These exercise the public API the way a userspace module (one that only
//  imports PropertyTestingKit) would — defining its own probe key, view, and
//  scheduler — to prove the engine names no specific signal.
//

import Testing
@testable import PropertyTestingKit
@testable import FuzzCore

@Suite("Instrumentation seam")
struct InstrumentationSeamTests {

    // A userspace-style signal: a probe-produced view keyed by its own type.
    struct CountView { let edges: Int }
    enum CountKey: InstrumentationKey { typealias View = CountView }

    struct LabelView { let value: String }
    enum LabelKey: InstrumentationKey { typealias View = LabelView }

    // MARK: - RawExecutionContext registry

    @Test("Context returns a registered view by its key")
    func contextReturnsRegisteredView() {
        var ctx = RawExecutionContext()
        ctx.set(CountKey.self, CountView(edges: 7))
        #expect(ctx[CountKey.self]?.edges == 7)
    }

    @Test("Context returns nil for an unregistered key")
    func contextReturnsNilForAbsentKey() {
        var ctx = RawExecutionContext()
        ctx.set(CountKey.self, CountView(edges: 7))
        #expect(ctx[LabelKey.self] == nil)
    }

    @Test("Views are keyed independently by type")
    func viewsAreKeyedByType() {
        var ctx = RawExecutionContext()
        ctx.set(CountKey.self, CountView(edges: 1))
        ctx.set(LabelKey.self, LabelView(value: "x"))
        #expect(ctx[CountKey.self]?.edges == 1)
        #expect(ctx[LabelKey.self]?.value == "x")
    }

    // MARK: - InstrumentationProbe

    final class CountProbe: InstrumentationProbe {
        typealias Key = CountKey
        var didSetUp = false
        var resetCount = 0
        var nextEdges = 0
        func setUp() { didSetUp = true }
        func reset() { resetCount += 1 }
        func makeView() -> CountView { CountView(edges: nextEdges) }
    }

    @Test("A probe contributes its view into a context under its key")
    func probeContributesView() {
        let probe = CountProbe()
        probe.nextEdges = 42
        var ctx = RawExecutionContext()
        probe.contribute(to: &ctx)
        #expect(ctx[CountKey.self]?.edges == 42)
    }

    @Test("Probe lifecycle hooks have working defaults and overrides")
    func probeLifecycle() {
        let probe = CountProbe()
        #expect(probe.didSetUp == false)
        probe.setUp()
        probe.reset()
        probe.reset()
        #expect(probe.didSetUp == true)
        #expect(probe.resetCount == 2)
    }

    // MARK: - Scheduler seam (userspace-style)

    /// A scheduler that reads the count probe and retains inputs that covered
    /// something — proving a scheduler decides admission purely from a view it
    /// asked for, owns its own production, and erases behind `AnyScheduler` with
    /// the engine naming no signal. Generic over the pack, like any real
    /// scheduler that owns the typed inputs it schedules.
    final class CountThresholdScheduler<each Input: Codable & Sendable> {
        let requiredProbes: [any InstrumentationKey.Type] = [CountKey.self]
        private(set) var observedEdges: [Int] = []
        private let produce: () -> ScheduledInput<repeat each Input>

        init(produce: @escaping () -> ScheduledInput<repeat each Input>) {
            self.produce = produce
        }

        func next() -> ScheduledInput<repeat each Input> { produce() }

        func observe(
            _ input: (repeat each Input),
            _ context: RawExecutionContext,
            source: SchedulerSource
        ) -> SparseCoverage? {
            guard let view = context[CountKey.self] else { return nil }
            observedEdges.append(view.edges)
            guard view.edges > 0 else { return nil }
            return SparseCoverage()  // a non-nil signature ⇒ retain
        }

        func erased() -> AnyScheduler<repeat each Input> {
            AnyScheduler(
                requiredProbes: requiredProbes,
                next: { self.next() },
                observe: { self.observe($0, $1, source: $2) }
            )
        }
    }

    @Test("A scheduler reads its required probe and signals admission")
    func schedulerReadsProbeAndAdmits() {
        let sched = CountThresholdScheduler<Int>(
            produce: { ScheduledInput(input: 0, poolParentID: nil) })

        var hit = RawExecutionContext()
        hit.set(CountKey.self, CountView(edges: 3))
        #expect(sched.observe(0, hit, source: .scheduled) != nil)
        #expect(sched.observedEdges == [3])

        var miss = RawExecutionContext()
        miss.set(CountKey.self, CountView(edges: 0))
        #expect(sched.observe(0, miss, source: .scheduled) == nil)
    }

    @Test("A scheduler retains nothing when its probe is absent")
    func schedulerIgnoresAbsentProbe() {
        let sched = CountThresholdScheduler<Int>(
            produce: { ScheduledInput(input: 0, poolParentID: nil) })
        #expect(sched.observe(0, RawExecutionContext(), source: .external) == nil)
        #expect(sched.observedEdges.isEmpty)
    }

    @Test("requiredProbes advertises the scheduler's instrumentation needs")
    func requiredProbesAdvertised() {
        let sched = CountThresholdScheduler<Int>(
            produce: { ScheduledInput(input: 0, poolParentID: nil) })
        #expect(sched.erased().requiredProbes.contains {
            ObjectIdentifier($0) == ObjectIdentifier(CountKey.self)
        })
    }

    @Test("next produces the scheduler's chosen input, erased behind AnyScheduler")
    func nextProducesChosenInput() {
        let sched = CountThresholdScheduler<Int>(
            produce: { ScheduledInput(input: 99, poolParentID: 5) })
        let produced = sched.erased().next()
        #expect(produced.input == 99)
        #expect(produced.poolParentID == 5)
    }
}
