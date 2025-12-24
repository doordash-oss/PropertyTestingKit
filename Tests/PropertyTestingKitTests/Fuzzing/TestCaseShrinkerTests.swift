//
//  TestCaseShrinkerTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
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

    // MARK: - IntegerShrinker Tests

    @Test("Integer shrinker generates candidates toward zero")
    func testIntegerShrinkerTowardZero() {
        let candidates = IntegerShrinker.candidates(for: 100, toward: 0)

        #expect(candidates.contains(0))
        #expect(candidates.contains(50))
        #expect(candidates.contains(99))
    }

    @Test("Integer shrinker generates candidates for negative")
    func testIntegerShrinkerNegative() {
        let candidates = IntegerShrinker.candidates(for: -50, toward: 0)

        #expect(candidates.contains(0))
        #expect(candidates.contains(-25))
    }

    @Test("Integer shrinker handles zero")
    func testIntegerShrinkerZero() {
        let candidates = IntegerShrinker.candidates(for: 0, toward: 0)

        // Zero shrinking to zero should have no candidates
        #expect(!candidates.contains(0))
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
        let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig(
            timeout: 0.05 // Very short timeout
        ))

        // Create array where failure requires specific element
        let largeArray = Array(0..<500) + [999]
        let (minimized, stats) = await shrinker.shrink(input: largeArray) { candidate in
            // Slow test that requires 999
            try? await Task.sleep(for: .milliseconds(20))
            return candidate.contains(999) ? .fail : .pass
        }

        // With short timeout and slow tests, should either timeout or complete quickly
        #expect(minimized.contains(999)) // Must still contain the failing element
        #expect(stats.duration <= 0.5) // Should complete relatively quickly
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

    // MARK: - ShrinkableInt Tests

    @Test("ShrinkableInt wraps value")
    func testShrinkableIntWraps() {
        let shrinkable = ShrinkableInt(42)
        #expect(shrinkable.value == 42)
        #expect(shrinkable.shrinkableElementCount == 42)
    }

    @Test("ShrinkableInt simplified candidates")
    func testShrinkableIntSimplified() {
        let shrinkable = ShrinkableInt(100)
        let candidates = shrinkable.simplifiedCandidates()

        #expect(candidates.contains { $0.value == 0 })
        #expect(candidates.contains { $0.value == 50 })
    }

    // MARK: - Helper Function Tests

    @Test("shrinkFailingInput helper works")
    func testShrinkFailingInputHelper() async {
        let (minimized, stats) = await shrinkFailingInput([1, 2, 3, 42, 5, 6]) { candidate in
            candidate.contains(42) ? .fail : .pass
        }

        #expect(minimized.contains(42))
        #expect(stats.candidatesTested > 0)
    }
}
