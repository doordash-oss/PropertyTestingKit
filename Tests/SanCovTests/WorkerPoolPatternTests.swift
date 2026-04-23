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

//  Tests that verify begin/endMeasurement work correctly when the same task
//  calls them multiple times in a loop (the worker pool pattern).
//

import Testing
import SanCovHooks
import Foundation

@Suite("Worker Pool Pattern Tests")
struct WorkerPoolPatternTests {

    /// Mirrors the FuzzStateMachine worker pool pattern:
    /// - Create a task group with N workers
    /// - Each worker runs begin/endMeasurement in a loop
    /// - Same task pointer is used for multiple measurements
    @Test("Same task can run multiple measurements in a loop")
    func testSameTaskMultipleMeasurements() async {
        let iterationsPerWorker = 100
        let workerCount = 16

        // Track that we successfully completed all iterations
        actor Counter {
            var count = 0
            func increment() { count += 1 }
            func getCount() -> Int { count }
        }
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    // This is the pattern: same task runs multiple measurements
                    for _ in 0..<iterationsPerWorker {
                        let context = sancov_begin_measurement()

                        // Simulate some work that triggers coverage
                        blackhole(simulateWork(42))

                        sancov_end_measurement(context)
                        await counter.increment()
                    }
                }
            }
        }

        let total = await counter.getCount()
        #expect(total == workerCount * iterationsPerWorker,
                "Expected \(workerCount * iterationsPerWorker) iterations, got \(total)")
    }

    /// More aggressive test: higher iteration count, check for heap corruption
    @Test("High iteration count stress test")
    func testHighIterationCount() async {
        let iterationsPerWorker = 1000
        let workerCount = ProcessInfo.processInfo.processorCount

        actor Counter {
            var count = 0
            var errors: [String] = []
            func increment() { count += 1 }
            func recordError(_ msg: String) { errors.append(msg) }
            func getCount() -> Int { count }
            func getErrors() -> [String] { errors }
        }
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<workerCount {
                group.addTask {
                    for iteration in 0..<iterationsPerWorker {
                        let context = sancov_begin_measurement()

                        guard context != nil else {
                            await counter.recordError("Worker \(workerIndex) iteration \(iteration): nil context")
                            continue
                        }

                        // Do some work
                        blackhole(simulateWork(iteration))

                        // Check coverage count is reasonable
                        let coveredCount = sancov_get_covered_count_with_context(context)
                        if coveredCount < 0 {
                            await counter.recordError("Worker \(workerIndex) iteration \(iteration): negative count \(coveredCount)")
                        }

                        sancov_end_measurement(context)
                        await counter.increment()
                    }
                }
            }
        }

        let errors = await counter.getErrors()
        let total = await counter.getCount()

        #expect(errors.isEmpty, "Errors occurred: \(errors.prefix(10))")
        #expect(total == workerCount * iterationsPerWorker,
                "Expected \(workerCount * iterationsPerWorker) iterations, got \(total)")
    }

    /// Test with async work between begin and end to encourage task hopping
    @Test("Measurements with async work (task hopping)")
    func testMeasurementsWithAsyncWork() async {
        let iterationsPerWorker = 50
        let workerCount = 8

        actor Counter {
            var count = 0
            func increment() { count += 1 }
            func getCount() -> Int { count }
        }
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    for _ in 0..<iterationsPerWorker {
                        let context = sancov_begin_measurement()

                        // Async work that might cause task to hop threads
                        await Task.yield()
                        blackhole(simulateWork(42))
                        await Task.yield()

                        sancov_end_measurement(context)
                        await counter.increment()
                    }
                }
            }
        }

        let total = await counter.getCount()
        #expect(total == workerCount * iterationsPerWorker)
    }
}

// MARK: - Helpers

/// Prevents the compiler from optimizing away the result
@inline(never)
func blackhole<T>(_ value: T) {
    withUnsafePointer(to: value) { _ in }
}

/// Simulates some work with branches to generate coverage
@inline(never)
func simulateWork(_ x: Int) -> Int {
    var result = x
    if x > 50 {
        result += 100
    } else if x > 25 {
        result += 50
    } else {
        result += 10
    }

    if x % 2 == 0 {
        result *= 2
    }

    return result
}
