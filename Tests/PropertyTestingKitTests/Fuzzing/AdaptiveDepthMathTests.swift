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

//  The pure scoring math for the productivity-weighted, adaptive-depth pool
//  policy. Two scores, both per-seed:
//   1. draw weight  — spikes ×(1+n) on an n-feature-owning mutant, decays ×0.95
//                     on a fruitless one. Asymptotic to 0, never 0.
//   2. depth cascade — per-level "advance past this depth" scores in [0, C<100);
//                     a miss climbs the stop level slowly toward C (never reaches
//                     it), a hit anchors it. Sampling walks the levels.
//  These functions are pinned here against hand-computed values; the policy
//  (AdaptiveDepthPolicy) wires them onto the pool event stream.
//

import Testing
@testable import PropertyTestingKit

@Suite("Adaptive-depth scoring math")
struct AdaptiveDepthMathTests {

    // MARK: - Score 1: draw weight

    @Test("owning n features multiplies weight by (1 + n)")
    func weightSpikesWithOwnership() {
        #expect(adaptiveDrawWeightUpdate(1.0, ownedFeatures: 3) == 4.0)
        #expect(adaptiveDrawWeightUpdate(2.0, ownedFeatures: 1) == 4.0)
        #expect(adaptiveDrawWeightUpdate(1.0, ownedFeatures: 1) == 2.0)
    }

    @Test("a fruitless mutant decays weight by 0.95")
    func weightDecaysOnMiss() {
        #expect(adaptiveDrawWeightUpdate(1.0, ownedFeatures: 0) == 0.95)
        #expect(adaptiveDrawWeightUpdate(10.0, ownedFeatures: 0) == 9.5)
    }

    @Test("weight never reaches zero under unbounded decay")
    func weightNeverZero() {
        var w = 1.0
        for _ in 0..<100_000 { w = adaptiveDrawWeightUpdate(w, ownedFeatures: 0) }
        #expect(w > 0.0)
    }

    // MARK: - Score 2: depth advance scores

    @Test("a miss climbs the level slowly toward the ceiling")
    func depthClimbsOnMiss() {
        // Formula characterization (explicit params, default-independent).
        // s=0, alpha=0.05, C=90 → 0 + 0.05*90 = 4.5
        #expect(depthAdvanceUpdate(0.0, hit: false, alpha: 0.05, ceiling: 90) == 4.5)
        // s=4.5 → 4.5 + 0.05*(90-4.5) = 4.5 + 4.275 = 8.775
        #expect(abs(depthAdvanceUpdate(4.5, hit: false, alpha: 0.05, ceiling: 90) - 8.775) < 1e-9)
    }

    @Test("tuned defaults climb slowly toward a low ceiling")
    func tunedDefaultsAreShallow() {
        // The swept optimum (alpha=0.02, ceiling=45) is the default: a miss from
        // 0 advances only 0.02*45 = 0.9 toward a 45 asymptote — far shallower than
        // the original 0.05/90 (which overshot into the 0%-productive deep tail).
        #expect(abs(depthAdvanceUpdate(0.0, hit: false) - 0.9) < 1e-9)
    }

    @Test("a hit anchors the level by decaying it")
    func depthAnchorsOnHit() {
        #expect(abs(depthAdvanceUpdate(10.0, hit: true) - 9.5) < 1e-9)
    }

    @Test("depth advance score never reaches the ceiling")
    func depthNeverReachesCeiling() {
        var s = 0.0
        for _ in 0..<100_000 { s = depthAdvanceUpdate(s, hit: false, alpha: 0.05, ceiling: 90) }
        #expect(s < 90.0)
    }

    // MARK: - Score 2: cascade sampling

    @Test("score 0 always stops at the current depth")
    func sampleStopsWhenScoreZero() {
        #expect(sampleMutationDepth(scores: [0.0], rolls: [50.0]) == 1)
    }

    @Test("roll below the level's score advances deeper")
    func sampleAdvancesWhenRollBelowScore() {
        // [90]: r=50<90 → advance past the only level → new rung at depth 2
        #expect(sampleMutationDepth(scores: [90.0], rolls: [50.0]) == 2)
        // [90,90]: advance, advance → depth 3
        #expect(sampleMutationDepth(scores: [90.0, 90.0], rolls: [50.0, 50.0]) == 3)
    }

    @Test("roll at or above the level's score stops there")
    func sampleStopsWhenRollAboveScore() {
        #expect(sampleMutationDepth(scores: [90.0], rolls: [95.0]) == 1)
        // advance level 0 (40<50), stop at level 1 (60≥50) → depth 2
        #expect(sampleMutationDepth(scores: [50.0, 50.0], rolls: [40.0, 60.0]) == 2)
    }
}
