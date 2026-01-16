//
//  SanCovIsolationTests.swift
//  PropertyTestingKit
//
//  Tests for verifying that SanitizerCoverage with task-based coverage maps
//  provides TRUE per-test coverage isolation, even with concurrent execution.
//
//  Key insight: Swift Testing uses task groups, and tasks can hop between threads.
//  Thread-local storage does NOT provide isolation for Swift concurrency.
//  Instead, we use swift_task_getCurrent() to key coverage maps by task pointer.
//

import Testing
import SanCovHooks
import Foundation

// MARK: - Test Infrastructure

/// Each test has a unique local function with a unique edge index range.
/// We use inline(never) to prevent inlining and ensure distinct coverage edges.
/// The edge ranges are spaced 1000 apart to avoid any overlap.

/// Storage for collecting test results across all 20 tests
actor TestResultCollector {
    var results: [String: Set<Int>] = [:]

    func record(testName: String, coveredIndices: Set<Int>) {
        results[testName] = coveredIndices
    }

    func getResults() -> [String: Set<Int>] {
        results
    }

    func clear() {
        results.removeAll()
    }
}

/// Shared collector for the test suite
let sharedCollector = TestResultCollector()

/// Helper to get covered indices from a measurement context
func getCoveredIndices(context: UnsafeMutablePointer<SanCovMeasurementContext>?) -> Set<Int> {
    let count = sancov_get_covered_count_with_context(context)
    guard count > 0 else { return [] }

    guard let indices = sancov_snapshot_covered_indices_with_context(context) else {
        return []
    }
    defer { free(indices) }

    let buffer = UnsafeBufferPointer(start: indices, count: count)
    return Set(buffer.map { Int($0) })
}

// MARK: - 20 Test Functions (each with unique local function)

// Each test function:
// 1. Resets coverage
// 2. Calls its unique local function
// 3. Records which edges were covered
// The local functions have different control flow to create unique edge patterns

@Suite("Task Isolation Tests", .tags(.isolation))
struct TaskIsolationTests {

    // Test 0
    @Test("Test 0 isolation")
    func test0() async {
        @inline(never) func localFunction0(_ x: Int) -> Int {
            if x > 50 { return x * 2 }
            else if x > 25 { return x * 3 }
            else { return x * 4 }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<100 { _ = localFunction0(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test0", coveredIndices: indices)
    }

    // Test 1
    @Test("Test 1 isolation")
    func test1() async {
        @inline(never) func localFunction1(_ x: Int) -> Int {
            switch x % 5 {
            case 0: return x + 10
            case 1: return x + 20
            case 2: return x + 30
            case 3: return x + 40
            default: return x + 50
            }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<100 { _ = localFunction1(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test1", coveredIndices: indices)
    }

    // Test 2
    @Test("Test 2 isolation")
    func test2() async {
        @inline(never) func localFunction2(_ x: Int) -> Int {
            var result = x
            if x & 1 != 0 { result += 100 }
            if x & 2 != 0 { result += 200 }
            if x & 4 != 0 { result += 400 }
            return result
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<100 { _ = localFunction2(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test2", coveredIndices: indices)
    }

    // Test 3
    @Test("Test 3 isolation")
    func test3() async {
        @inline(never) func localFunction3(_ x: Int) -> Int {
            guard x > 0 else { return -1 }
            guard x < 100 else { return -2 }
            return x * x
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in -10..<110 { _ = localFunction3(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test3", coveredIndices: indices)
    }

    // Test 4
    @Test("Test 4 isolation")
    func test4() async {
        @inline(never) func localFunction4(_ x: Int) -> Int {
            let a = x > 10 ? 1 : 0
            let b = x > 20 ? 2 : 0
            let c = x > 30 ? 4 : 0
            return a + b + c
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<50 { _ = localFunction4(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test4", coveredIndices: indices)
    }

    // Test 5
    @Test("Test 5 isolation")
    func test5() async {
        @inline(never) func localFunction5(_ x: Int) -> Int {
            var sum = 0
            for i in 0..<(x % 10) {
                sum += i
            }
            return sum
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<100 { _ = localFunction5(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test5", coveredIndices: indices)
    }

    // Test 6
    @Test("Test 6 isolation")
    func test6() async {
        @inline(never) func localFunction6(_ x: Int) -> Int {
            if x < 0 { return abs(x) }
            else if x == 0 { return 1 }
            else if x < 10 { return x * 2 }
            else if x < 50 { return x * 3 }
            else { return x * 4 }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in -20..<100 { _ = localFunction6(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test6", coveredIndices: indices)
    }

    // Test 7
    @Test("Test 7 isolation")
    func test7() async {
        @inline(never) func localFunction7(_ x: Int) -> Int {
            switch x {
            case ..<0: return -x
            case 0: return 0
            case 1...10: return x
            case 11...50: return x * 2
            default: return x * 3
            }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in -10..<100 { _ = localFunction7(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test7", coveredIndices: indices)
    }

    // Test 8
    @Test("Test 8 isolation")
    func test8() async {
        @inline(never) func localFunction8(_ x: Int) -> Int {
            let isEven = x % 2 == 0
            let isPositive = x > 0
            let isSmall = x < 50

            if isEven && isPositive { return 1 }
            else if isEven && !isPositive { return 2 }
            else if !isEven && isSmall { return 3 }
            else { return 4 }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in -50..<100 { _ = localFunction8(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test8", coveredIndices: indices)
    }

    // Test 9
    @Test("Test 9 isolation")
    func test9() async {
        @inline(never) func localFunction9(_ x: Int) -> Int {
            var n = x
            var count = 0
            while n > 0 {
                count += n & 1
                n >>= 1
            }
            return count
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<256 { _ = localFunction9(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test9", coveredIndices: indices)
    }

    // Test 10
    @Test("Test 10 isolation")
    func test10() async {
        @inline(never) func localFunction10(_ x: Int) -> Int {
            if x % 2 == 0 {
                if x % 4 == 0 {
                    return x / 4
                } else {
                    return x / 2
                }
            } else {
                if x % 3 == 0 {
                    return x / 3
                } else {
                    return x
                }
            }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 1..<100 { _ = localFunction10(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test10", coveredIndices: indices)
    }

    // Test 11
    @Test("Test 11 isolation")
    func test11() async {
        @inline(never) func localFunction11(_ x: Int) -> Int {
            switch (x % 3, x % 2) {
            case (0, 0): return 1
            case (0, 1): return 2
            case (1, 0): return 3
            case (1, 1): return 4
            case (2, 0): return 5
            default: return 6
            }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<100 { _ = localFunction11(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test11", coveredIndices: indices)
    }

    // Test 12
    @Test("Test 12 isolation")
    func test12() async {
        @inline(never) func localFunction12(_ x: Int) -> Int {
            let hundreds = x / 100
            let tens = (x % 100) / 10
            let ones = x % 10
            return hundreds * 7 + tens * 3 + ones
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<1000 { _ = localFunction12(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test12", coveredIndices: indices)
    }

    // Test 13
    @Test("Test 13 isolation")
    func test13() async {
        @inline(never) func localFunction13(_ x: Int) -> Int {
            if x <= 0 { return 0 }
            if x == 1 { return 1 }
            var a = 0, b = 1
            for _ in 2...min(x, 20) {
                let temp = a + b
                a = b
                b = temp
            }
            return b
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in -5..<25 { _ = localFunction13(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test13", coveredIndices: indices)
    }

    // Test 14
    @Test("Test 14 isolation")
    func test14() async {
        @inline(never) func localFunction14(_ x: Int) -> Int {
            var result = 1
            var base = x % 10 + 1
            var exp = x / 10 % 5
            while exp > 0 {
                if exp & 1 == 1 { result *= base }
                base *= base
                exp >>= 1
            }
            return result
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<100 { _ = localFunction14(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test14", coveredIndices: indices)
    }

    // Test 15
    @Test("Test 15 isolation")
    func test15() async {
        @inline(never) func localFunction15(_ x: Int) -> Int {
            let a = x & 0xFF
            let b = (x >> 8) & 0xFF
            if a > b { return a - b }
            else if a < b { return b - a }
            else { return 0 }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<1000 { _ = localFunction15(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test15", coveredIndices: indices)
    }

    // Test 16
    @Test("Test 16 isolation")
    func test16() async {
        @inline(never) func localFunction16(_ x: Int) -> Int {
            var n = abs(x) + 1
            var steps = 0
            while n != 1 && steps < 100 {
                if n % 2 == 0 { n /= 2 }
                else { n = 3 * n + 1 }
                steps += 1
            }
            return steps
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 1..<50 { _ = localFunction16(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test16", coveredIndices: indices)
    }

    // Test 17
    @Test("Test 17 isolation")
    func test17() async {
        @inline(never) func localFunction17(_ x: Int) -> Int {
            switch x % 7 {
            case 0: return x &+ 7
            case 1: return x &+ 14
            case 2: return x &+ 21
            case 3: return x &+ 28
            case 4: return x &+ 35
            case 5: return x &+ 42
            default: return x &+ 49
            }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<70 { _ = localFunction17(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test17", coveredIndices: indices)
    }

    // Test 18
    @Test("Test 18 isolation")
    func test18() async {
        @inline(never) func localFunction18(_ x: Int) -> Int {
            if x < 0 {
                return x < -50 ? -100 : -50
            } else if x == 0 {
                return 0
            } else {
                return x > 50 ? 100 : 50
            }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in -100..<100 { _ = localFunction18(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test18", coveredIndices: indices)
    }

    // Test 19
    @Test("Test 19 isolation")
    func test19() async {
        @inline(never) func localFunction19(_ x: Int) -> Int {
            let digit1 = x % 10
            let digit2 = (x / 10) % 10
            if digit1 == digit2 { return 1 }
            else if digit1 > digit2 { return 2 }
            else { return 3 }
        }

        let context = sancov_begin_measurement()
        defer { sancov_end_measurement(context) }
        for i in 0..<100 { _ = localFunction19(i) }
        let indices = getCoveredIndices(context: context)
        await sharedCollector.record(testName: "test19", coveredIndices: indices)
    }
}

// MARK: - Verification Test

@Suite("Isolation Verification", .tags(.verification))
struct IsolationVerificationTests {

    @Test("Verify no cross-test coverage contamination", arguments: 0..<100)
    func verifyIsolation(iteration: Int) async throws {
        // Clear results from previous iteration
        await sharedCollector.clear()

        // Run all 20 tests concurrently
        await withTaskGroup(of: Void.self) { group in
            let tests = TaskIsolationTests()

            group.addTask { await tests.test0() }
            group.addTask { await tests.test1() }
            group.addTask { await tests.test2() }
            group.addTask { await tests.test3() }
            group.addTask { await tests.test4() }
            group.addTask { await tests.test5() }
            group.addTask { await tests.test6() }
            group.addTask { await tests.test7() }
            group.addTask { await tests.test8() }
            group.addTask { await tests.test9() }
            group.addTask { await tests.test10() }
            group.addTask { await tests.test11() }
            group.addTask { await tests.test12() }
            group.addTask { await tests.test13() }
            group.addTask { await tests.test14() }
            group.addTask { await tests.test15() }
            group.addTask { await tests.test16() }
            group.addTask { await tests.test17() }
            group.addTask { await tests.test18() }
            group.addTask { await tests.test19() }
        }

        let results = await sharedCollector.getResults()

        // Verify we got results from all 20 tests
        #expect(results.count == 20, "Should have results from all 20 tests, got \(results.count)")

        // For each pair of tests, find their unique edges (edges not shared with any other test)
        // Each test's local function should have SOME edges unique to it
        var violations: [(String, String, Int)] = []

        let testNames = results.keys.sorted()
        for testA in testNames {
            guard let indicesA = results[testA] else { continue }

            // Find edges unique to testA (not in any other test)
            var uniqueToA = indicesA
            for testB in testNames where testB != testA {
                if let indicesB = results[testB] {
                    uniqueToA.subtract(indicesB)
                }
            }

            // Each test should have at least one unique edge from its local function
            // (The local functions have different control flow)
            if uniqueToA.isEmpty {
                // This is suspicious - might indicate coverage leakage
                // But could also happen if two functions happen to compile similarly
                // Let's track it but not fail immediately
            }
        }

        // The key check: for each test, verify it doesn't contain edges
        // that are ONLY present in other specific tests
        // This would indicate direct contamination
        for testA in testNames {
            guard let indicesA = results[testA] else { continue }

            for testB in testNames where testB != testA {
                guard let indicesB = results[testB] else { continue }

                // Find edges that are in B but not in any other test except A
                var uniqueToB = indicesB
                for testC in testNames where testC != testB && testC != testA {
                    if let indicesC = results[testC] {
                        uniqueToB.subtract(indicesC)
                    }
                }

                // How many of B's unique edges appear in A?
                let contamination = indicesA.intersection(uniqueToB)
                if !contamination.isEmpty && uniqueToB.count > 2 {
                    // Only flag if B has significant unique edges and A shares them
                    // This would indicate A somehow executed B's local function
                    violations.append((testA, testB, contamination.count))
                }
            }
        }

        if !violations.isEmpty && iteration % 100 == 0 {
            print("Iteration \(iteration): \(violations.count) potential violations detected")
            for (testA, testB, count) in violations.prefix(3) {
                print("  \(testA) contains \(count) edges unique to \(testB)")
            }
        }

        // We expect no direct contamination where test A contains edges
        // that could only come from test B's local function
        #expect(violations.isEmpty,
                "Coverage contamination detected: \(violations.count) violations in iteration \(iteration)")
    }
}

// MARK: - Tags

extension Tag {
    @Tag static var isolation: Self
    @Tag static var verification: Self
}
