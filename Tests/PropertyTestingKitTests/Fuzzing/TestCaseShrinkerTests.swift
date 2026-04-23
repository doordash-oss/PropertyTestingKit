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

//
//  TestCaseShrinkerTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
import Dependencies
@testable import PropertyTestingKit

@Suite("TestCaseShrinker")
struct TestCaseShrinkerTests {

    // MARK: - ShrinkConfig Tests

    @Test("ShrinkConfig has sensible defaults")
    func testShrinkConfigDefaults() {
        let config = ShrinkConfig()

        #expect(config.maxExecutions == 1000)
        #expect(config.timeout == 30)
        #expect(!config.verbose)
        #expect(config.initialGranularity == 2)
        #expect(config.minGranularity == 1)
    }

    // MARK: - Array Shrinkable Tests

    @Test("Array shrinkable element count")
    func testArrayShrinkableCount() {
        let array = [1, 2, 3, 4, 5]
        #expect(array.shrinkableElementCount == 5)
    }

    @Test("Array candidate removing range")
    func testArrayCandidateRemovingRange() {
        let array = [1, 2, 3, 4, 5]

        let candidate = array.candidateRemovingRange(1..<3)
        #expect(candidate == [1, 4, 5])
    }

    @Test("Array candidate removing out of bounds")
    func testArrayCandidateRemovingOutOfBounds() {
        let array = [1, 2, 3]

        let candidate = array.candidateRemovingRange(0..<10)
        #expect(candidate == nil)
    }

    // MARK: - String Shrinkable Tests

    @Test("String shrinkable element count")
    func testStringShrinkableCount() {
        let str = "hello"
        #expect(str.shrinkableElementCount == 5)
    }

    @Test("String candidate removing range")
    func testStringCandidateRemovingRange() {
        let str = "hello world"

        let candidate = str.candidateRemovingRange(5..<6)
        #expect(candidate == "helloworld")
    }

    @Test("String simplified candidates")
    func testStringSimplifiedCandidates() {
        let str = "HELLO"

        let candidates = str.simplifiedCandidates()
        #expect(candidates.contains("hello"))
        #expect(candidates.contains("aaaaa"))
        #expect(candidates.contains(""))
    }

    // MARK: - TestCaseShrinker Array Tests

    @Test("Shrinker reduces array to minimal failing element")
    func testShrinkerReducesArray() async {
        let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
            maxExecutions: 100,
            timeout: 10
        ))

        // Failure condition: array contains 42
        let (minimized, stats) = await shrinker.shrink(input: [1, 2, 42, 3, 4, 5]) { candidate in
            candidate.contains(42) ? .fail : .pass
        }

        #expect(minimized.contains(42))
        #expect(minimized.count <= 2) // Should reduce significantly
        #expect(stats.reductionRatio > 0.5)
    }

    @Test("Shrinker handles empty array")
    func testShrinkerEmptyArray() async {
        let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig())

        let (minimized, stats) = await shrinker.shrink(input: []) { _ in .fail }

        #expect(minimized.isEmpty)
        #expect(stats.minimizedSize == 0)
    }

    @Test("Shrinker respects max executions")
    func testShrinkerMaxExecutions() async {
        let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
            maxExecutions: 5
        ))

        // Create array where failure requires specific element
        let largeArray = Array(0..<100) + [999] + Array(100..<200)
        let (minimized, stats) = await shrinker.shrink(input: largeArray) { candidate in
            // Failure requires 999 to be present
            candidate.contains(999) ? .fail : .pass
        }

        // Either we hit max executions, or we successfully shrunk with few tests
        #expect(stats.candidatesTested <= 10)
        #expect(minimized.contains(999)) // Must still contain the failing element
    }

    @Test("Shrinker respects timeout")
    func testShrinkerTimeout() async {
        // Use injected time instead of actual sleep for deterministic testing
        let currentTime = SyncBox(Date(timeIntervalSince1970: 0))

        let (minimized, stats) = await withDependencies {
            $0.dateClient = DateClient(now: { currentTime.value })
        } operation: {
            let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
                timeout: 0.05 // Very short timeout (50ms)
            ))

            // Create array where failure requires specific element
            let largeArray = Array(0..<500) + [999]
            return await shrinker.shrink(input: largeArray) { candidate in
                // Simulate slow test by advancing time (20ms per test)
                currentTime.update { $0 = $0.addingTimeInterval(0.02) }
                return candidate.contains(999) ? .fail : .pass
            }
        }

        // With 50ms timeout and 20ms per test, should timeout after ~2-3 tests
        #expect(minimized.contains(999)) // Must still contain the failing element
        #expect(stats.timedOut, "Should have timed out")
        #expect(stats.candidatesTested <= 5, "Should stop after few tests due to timeout")
    }

    // MARK: - TestCaseShrinker String Tests

    @Test("Shrinker reduces string")
    func testShrinkerReducesString() async {
        let shrinker = TestCaseShrinker<String>(config: ShrinkConfig(
            maxExecutions: 100
        ))

        // Failure condition: string contains "error"
        let (minimized, stats) = await shrinker.shrink(
            input: "This is an error message with lots of extra text"
        ) { candidate in
            candidate.contains("error") ? .fail : .pass
        }

        #expect(minimized.contains("error"))
        #expect(minimized.count < 48) // Should reduce
        #expect(stats.reductionRatio > 0)
    }

    // MARK: - ShrinkStats Tests

    @Test("ShrinkStats computes reduction ratio")
    func testShrinkStatsReductionRatio() {
        let stats = ShrinkStats(
            candidatesTested: 10,
            originalSize: 100,
            minimizedSize: 10,
            duration: 1.0,
            timedOut: false,
            maxExecutionsReached: false
        )

        #expect(stats.reductionRatio == 0.9)
    }

    @Test("ShrinkStats handles zero original size")
    func testShrinkStatsZeroOriginal() {
        let stats = ShrinkStats(
            candidatesTested: 0,
            originalSize: 0,
            minimizedSize: 0,
            duration: 0,
            timedOut: false,
            maxExecutionsReached: false
        )

        #expect(stats.reductionRatio == 0)
    }

    @Test("ShrinkStats report contains info")
    func testShrinkStatsReport() {
        let stats = ShrinkStats(
            candidatesTested: 50,
            originalSize: 100,
            minimizedSize: 5,
            duration: 2.5,
            timedOut: false,
            maxExecutionsReached: false
        )

        let report = stats.report()
        #expect(report.contains("Original size: 100"))
        #expect(report.contains("Minimized size: 5"))
        #expect(report.contains("95.0%"))
    }

    // MARK: - MultiComponentShrinker Tests

    @Test("MultiComponentShrinker shrinks both components")
    func testMultiComponentShrinker() async {
        let shrinker = MultiComponentShrinker(config: ShrinkConfig(
            maxExecutions: 100
        ))

        // Failure: first array contains 5 AND second string contains "x"
        let input = ([1, 2, 3, 4, 5, 6, 7], "abcxdef")
        let (minimized, stats) = await shrinker.shrink(input: input) { (arr, str) in
            (arr.contains(5) && str.contains("x")) ? .fail : .pass
        }

        #expect(minimized.0.contains(5))
        #expect(minimized.1.contains("x"))
        #expect(minimized.0.count < 7)
        #expect(minimized.1.count < 7)
        #expect(stats.reductionRatio > 0)
    }

    // MARK: - Void-Returning Test Overload Tests

    @Test("Shrinker detects failure from thrown error")
    func testShrinkerVoidThrowingTest() async {
        let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
            maxExecutions: 100
        ))

        struct TestError: Error {}

        // Test throws when array contains 42
        let (minimized, stats) = await shrinker.shrink(input: [1, 2, 42, 3, 4, 5]) { candidate in
            if candidate.contains(42) {
                throw TestError()
            }
        }

        #expect(minimized.contains(42))
        #expect(minimized.count <= 2)
        #expect(stats.reductionRatio > 0.5)
    }

    @Test("Shrinker detects failure from recorded issue")
    func testShrinkerVoidExpectTest() async {
        let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
            maxExecutions: 100
        ))

        // Test records issue when array contains 42
        let (minimized, stats) = await shrinker.shrink(input: [1, 2, 42, 3, 4, 5]) { candidate in
            #expect(!candidate.contains(42))
        }

        #expect(minimized.contains(42))
        #expect(minimized.count <= 2)
        #expect(stats.reductionRatio > 0.5)
    }

    @Test("Shrinker void test detects pass when no failure")
    func testShrinkerVoidPassingTest() async {
        let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
            maxExecutions: 50
        ))

        // Test never fails - nothing to shrink to
        let (minimized, stats) = await shrinker.shrink(input: [1, 2, 3, 4, 5]) { (_: [Int]) in
            // All inputs pass - do nothing
        }

        // Since all candidates pass, original should be returned unchanged
        #expect(minimized == [1, 2, 3, 4, 5])
        #expect(stats.minimizedSize == 5)
    }

    @Test("MultiComponentShrinker void test with thrown error")
    func testMultiComponentShrinkerVoidThrowingTest() async {
        let shrinker = MultiComponentShrinker(config: ShrinkConfig(
            maxExecutions: 100
        ))

        struct TestError: Error {}

        // Failure: first array contains 5 AND second string contains "x"
        let input = ([1, 2, 3, 4, 5, 6, 7], "abcxdef")
        let (minimized, stats) = await shrinker.shrink(input: input) { (arr: [Int], str: String) in
            if arr.contains(5) && str.contains("x") {
                throw TestError()
            }
        }

        #expect(minimized.0.contains(5))
        #expect(minimized.1.contains("x"))
        #expect(minimized.0.count < 7)
        #expect(minimized.1.count < 7)
        #expect(stats.reductionRatio > 0)
    }

    @Test("MultiComponentShrinker void test with recorded issue")
    func testMultiComponentShrinkerVoidExpectTest() async {
        let shrinker = MultiComponentShrinker(config: ShrinkConfig(
            maxExecutions: 100
        ))

        // Failure: first array contains 5 AND second string contains "x"
        let input = ([1, 2, 3, 4, 5, 6, 7], "abcxdef")
        let (minimized, stats) = await shrinker.shrink(input: input) { (arr: [Int], str: String) in
            #expect(!(arr.contains(5) && str.contains("x")))
        }

        #expect(minimized.0.contains(5))
        #expect(minimized.1.contains("x"))
        #expect(minimized.0.count < 7)
        #expect(minimized.1.count < 7)
        #expect(stats.reductionRatio > 0)
    }
}
