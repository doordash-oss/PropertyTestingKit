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

//  Diagnostic hook on the scheduler's per-iteration draw decision. Fires once
//  per scheduler-driven iteration with what the scheduler chose (generate /
//  queue / mutate which pool seed), at what mutation depth, and whether the
//  resulting input was admitted to the pool (i.e. took ownership of a feature).
//
//  This is how experiments answer "are we spending iterations productively":
//  draw concentration (counts per parent), depth spread (depth histogram), and
//  productivity (accepted / total per source) are all reconstructable from the
//  event stream. `nil` (the default) is zero overhead — same pattern as the
//  STLC `ShiftProbe`. Set via `SchedulerProbe.$observe.withValue { ... }`.

public enum SchedulerProbe {
    /// `(source, depth, accepted)` — fired after the scheduler observes the
    /// iteration's outcome. `depth` is the executed mutation depth (1 for
    /// generate/queue/seed inputs); `accepted` is true when the input was
    /// admitted to the pool.
    @TaskLocal public static var observe: (@Sendable (_ source: PoolIterationSource, _ depth: Int, _ accepted: Bool) -> Void)?
}
