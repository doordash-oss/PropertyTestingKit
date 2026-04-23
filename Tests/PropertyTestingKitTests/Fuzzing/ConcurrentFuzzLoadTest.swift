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

import Testing
@testable import PropertyTestingKit
import Foundation

//@Suite("Concurrent Fuzz Load Test")
//struct ConcurrentFuzzLoadTest {
//
//    @Test("20 concurrent fuzzers - hash table load test")
//    func twentyConcurrentFuzzers() async throws {
//        let concurrentEngines = 20
//
//        await withTaskGroup(of: Void.self) { group in
//            for _ in 0..<concurrentEngines {
//                group.addTask {
//                    let config = FuzzEngine<Int>.Config(
//                        mutationBatchSize: 1  // Sequential within each engine to maximize concurrent measurements
//                    )
//                    let engine = FuzzEngine<Int>(config: config)
//                    let _ = await engine.run { input in
//                        do {
//                            try expensiveValidation(input)
//                        } catch {
//                            print("threw error \(error)")
//                        }
//                    }
//                }
//            }
//
//            await group.waitForAll()
//        }
//
//        // If we get here without crashing, the concurrent access worked
//        #expect(true, "20 concurrent fuzzers completed successfully")
//    }
//
//    @Test("40 concurrent fuzzers - higher load test")
//    func fortyConcurrentFuzzers() async throws {
//        let concurrentEngines = 40
//
//        await withTaskGroup(of: Void.self) { group in
//            for _ in 0..<concurrentEngines {
//                group.addTask {
//                    let config = FuzzEngine<Int>.Config(
//                        mutationBatchSize: 1
//                    )
//                    let engine = FuzzEngine<Int>(config: config)
//                    let _ = await engine.run { input in
//                        do {
//                            try expensiveValidation(input)
//                        } catch {
//                            print("threw error \(error)")
//                        }
//                    }
//                }
//            }
//            await group.waitForAll()
//        }
//
//        #expect(true, "40 concurrent fuzzers completed successfully")
//    }
//
//    @Test("20 concurrent fuzzers with batched mutations")
//    func twentyConcurrentFuzzersWithBatching() async throws {
//        let concurrentEngines = 200
//        let iterationsPerEngine = 1000
//
//        await withTaskGroup(of: Void.self) { group in
//            for _ in 0..<concurrentEngines {
//                group.addTask {
//                    let config = FuzzEngine<Int>.Config(
//                        maxIterations: iterationsPerEngine,
//                        mutationBatchSize: 16  // Batched - each engine runs 8 tests concurrently
//                    )
//                    let engine = FuzzEngine<Int>(config: config)
//                    let _ = await engine.run { input in
//                        do {
//                            try await asyncValidation(input)
//                        } catch {
//                            print("threw error \(error)")
//                        }
//
//                    }
//                }
//            }
//            await group.waitForAll()
//        }
//
//        // With 20 engines * 8 batch size = up to 160 concurrent measurements
//        #expect(true, "20 concurrent fuzzers with batching completed successfully")
//    }
//}

func asyncValidation(_ input: Int) async throws {
    try await Task.sleep(for: Duration.seconds(1))
}

func expensiveValidation(_ input: Int) throws {
    // Simulate parsing/validation work with many branches
    var accumulator: Int = 0

    // Multiple passes over the input to create measurable work
    for iteration in 0..<100 {
        let adjusted = input &+ iteration

        if adjusted < 0 {
            accumulator &+= hashValue(adjusted, seed: 1)
        } else if adjusted == 0 {
            accumulator &+= hashValue(adjusted, seed: 2)
        } else if adjusted < 100 {
            accumulator &+= hashValue(adjusted, seed: 3)
        } else if adjusted < 1000 {
            accumulator &+= hashValue(adjusted, seed: 4)
        } else if adjusted < 10000 {
            accumulator &+= hashValue(adjusted, seed: 5)
        } else {
            accumulator &+= hashValue(adjusted, seed: 6)
        }

        // Add more branching based on bits
        if adjusted & 1 != 0 {
            accumulator &+= hashValue(adjusted, seed: 7)
        }
        if adjusted & 2 != 0 {
            accumulator &+= hashValue(adjusted, seed: 8)
        }
        if adjusted & 4 != 0 {
            accumulator &+= hashValue(adjusted, seed: 9)
        }
        if adjusted & 8 != 0 {
            accumulator &+= hashValue(adjusted, seed: 10)
        }
    }

    blackHole(accumulator)
}

func hashValue(_ value: Int, seed: Int) -> Int {
    var result = value ^ seed
    for _ in 0..<10 {
        result = result &* 31 &+ seed
        result = result ^ (result >> 7)
    }
    return result
}

@_optimize(none) // Used after tip here: https://forums.swift.org/t/compiler-swallows-blackhole/64305/10 - see also https://github.com/apple/swift/commit/1fceeab71e79dc96f1b6f560bf745b016d7fcdcf
func blackHole(_: some Any) {}
