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

//  Tests for ComparisonDictionary: the learned pool of comparison operands that
//  backs input-to-state mutation. Operands captured by the cmp observer land
//  here; numeric mutators sample from `.current` to jump straight to a value a
//  comparison cared about.
//

import Testing
@testable import PropertyTestingKit

@Suite("ComparisonDictionary")
struct ComparisonDictionaryTests {

    @Test("An empty dictionary samples nil")
    func emptySamplesNil() {
        let dict = ComparisonDictionary()
        var rng = FastRNG()
        #expect(dict.randomValue(using: &rng) == nil)
        #expect(dict.isEmpty)
    }

    @Test("A recorded value is sampled back")
    func recordedValueIsSampled() {
        let dict = ComparisonDictionary()
        dict.record(0xDEADBEEF)
        var rng = FastRNG()
        #expect(!dict.isEmpty)
        #expect(dict.randomValue(using: &rng) == 0xDEADBEEF)
    }

    @Test("Sampling only ever returns recorded values")
    func samplingReturnsOnlyRecorded() {
        let dict = ComparisonDictionary()
        let recorded: Set<UInt64> = [10, 20, 30, 40]
        for v in recorded { dict.record(v) }
        var rng = FastRNG()
        for _ in 0..<100 {
            guard let v = dict.randomValue(using: &rng) else {
                Issue.record("non-empty dictionary returned nil")
                return
            }
            #expect(recorded.contains(v))
        }
    }

    @Test("The dictionary is bounded to its capacity (ring eviction)")
    func boundedToCapacity() {
        let dict = ComparisonDictionary(capacity: 8)
        // Record well past capacity; only the most recent `capacity` survive.
        for v in 0..<100 { dict.record(UInt64(v)) }
        var rng = FastRNG()
        var seen = Set<UInt64>()
        for _ in 0..<500 {
            if let v = dict.randomValue(using: &rng) { seen.insert(v) }
        }
        #expect(seen.count <= 8, "at most `capacity` distinct values are retained")
        // The oldest values (0, 1, ...) must have been evicted by the newest.
        #expect(!seen.contains(0), "the oldest recorded value is evicted")
        #expect(seen.contains(99), "the most recent recorded value is retained")
    }

    @Test("current is nil outside a withValue scope")
    func currentNilByDefault() {
        #expect(ComparisonDictionary.current == nil)
    }

    @Test("withValue installs the dictionary as current for the scope")
    func withValueInstallsCurrent() {
        let dict = ComparisonDictionary()
        #expect(ComparisonDictionary.current == nil)
        ComparisonDictionary.$current.withValue(dict) {
            #expect(ComparisonDictionary.current === dict)
        }
        #expect(ComparisonDictionary.current == nil, "current is restored after the scope")
    }
}
