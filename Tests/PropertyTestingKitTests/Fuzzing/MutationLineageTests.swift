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

//  Mutation lineage: a plugin tags `selectForMutation` with an opaque
//  `originID`; the engine carries it through the pending queue and reports it
//  back as `parentID` on every iteration that executed one of those mutants.
//  This is what lets a scheduler attribute discoveries (and execution counts)
//  to the seed that spawned them.
//

import Testing
@testable import PropertyTestingKit

@Suite("Mutation lineage")
struct MutationLineageTests {

    @Test("originID rides the queue and returns as parentID on mutant iterations")
    func originIDReturnsAsParentID() async throws {
        let queueParents = SyncBox<Set<Int>>([])
        let generatedParents = SyncBox<Set<Int>>([])  // non-nil parentIDs on generated inputs (must stay empty)
        let tagged = SyncBox<Bool>(false)

        let probe = FuzzPlugin<Int>(id: "lineage_probe", handleSync: { event in
            switch event {
            case let .iteration(ctx):
                if ctx.fromMutationQueue {
                    if let p = ctx.parentID {
                        queueParents.update { _ = $0.insert(p) }
                        return [.stop(.init(reason: .custom("lineage_observed")))]
                    }
                } else if let p = ctx.parentID {
                    generatedParents.update { _ = $0.insert(p) }
                }
                // Tag the first discovery with a recognizable origin.
                if ctx.newCoverage != nil, !tagged.value {
                    tagged.update { $0 = true }
                    return [.selectForMutation(.init(input: ctx.input, originID: 7))]
                }
                return []
            }
        })

        _ = try await fuzz(
            duration: .seconds(10),
            persistence: .ephemeral,
            parallelism: 1,
            plugins: { [probe] }
        ) { (input: Int) in
            blackHole(input)
        }

        #expect(queueParents.value == [7],
                "mutants of the tagged seed must report its originID as parentID")
        #expect(generatedParents.value.isEmpty,
                "freshly generated inputs have no parent")
    }
}
