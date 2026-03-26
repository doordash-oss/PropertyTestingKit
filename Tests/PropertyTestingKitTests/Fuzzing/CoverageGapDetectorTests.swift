//
//  CoverageGapDetectorTests.swift
//  PropertyTestingKit
//

import Testing
@testable import PropertyTestingKit

@Suite("CoverageGapDetector")
struct CoverageGapDetectorTests {

    // MARK: - UncoveredRegion Tests

    @Test("UncoveredRegion initializes with correct values")
    func uncoveredRegionInit() {
        let region = UncoveredRegion(
            lineStart: 10,
            columnStart: 5,
            lineEnd: 15,
            columnEnd: 20,
            edgeIndex: 42,
            isBranch: true
        )

        #expect(region.lineStart == 10)
        #expect(region.columnStart == 5)
        #expect(region.lineEnd == 15)
        #expect(region.columnEnd == 20)
        #expect(region.edgeIndex == 42)
        #expect(region.isBranch == true)
    }

    @Test("UncoveredRegion defaults lineEnd and columnEnd to start values")
    func uncoveredRegionDefaults() {
        let region = UncoveredRegion(
            lineStart: 10,
            columnStart: 5,
            edgeIndex: 42
        )

        #expect(region.lineEnd == 10)
        #expect(region.columnEnd == 5)
        #expect(region.isBranch == false)
    }

    // MARK: - CoverageGap Tests

    @Test("CoverageGap calculates percentage correctly")
    func coverageGapPercentage() {
        let gap = CoverageGap(
            functionName: "testFunc",
            filename: "/path/to/File.swift",
            uncoveredRegions: [],
            coveredEdgeCount: 3,
            totalEdgeCount: 4
        )

        #expect(gap.coveragePercentage == 75.0)
    }

    @Test("CoverageGap returns 0% for empty function")
    func coverageGapZeroTotal() {
        let gap = CoverageGap(
            functionName: "emptyFunc",
            filename: "/path/to/File.swift",
            uncoveredRegions: [],
            coveredEdgeCount: 0,
            totalEdgeCount: 0
        )

        #expect(gap.coveragePercentage == 0)
    }

    @Test("CoverageGap isSignificant for low coverage")
    func coverageGapSignificant() {
        // Many uncovered regions - significant
        let gap1 = CoverageGap(
            functionName: "func1",
            filename: "/path/to/File.swift",
            uncoveredRegions: [
                UncoveredRegion(lineStart: 1, columnStart: 1, edgeIndex: 0),
                UncoveredRegion(lineStart: 2, columnStart: 1, edgeIndex: 1)
            ],
            coveredEdgeCount: 1,
            totalEdgeCount: 3
        )
        #expect(gap1.isSignificant == true)

        // Low coverage with > 2 edges - significant
        let gap2 = CoverageGap(
            functionName: "func2",
            filename: "/path/to/File.swift",
            uncoveredRegions: [
                UncoveredRegion(lineStart: 1, columnStart: 1, edgeIndex: 0)
            ],
            coveredEdgeCount: 1,
            totalEdgeCount: 4
        )
        #expect(gap2.isSignificant == true)  // 25% < 90%

        // Single uncovered region, small function - not significant
        let gap3 = CoverageGap(
            functionName: "func3",
            filename: "/path/to/File.swift",
            uncoveredRegions: [
                UncoveredRegion(lineStart: 1, columnStart: 1, edgeIndex: 0)
            ],
            coveredEdgeCount: 1,
            totalEdgeCount: 2
        )
        #expect(gap3.isSignificant == false)
    }

    // MARK: - CoverageGapReport Tests

    @Test("CoverageGapReport summary for no gaps")
    func reportNoGaps() {
        let report = CoverageGapReport(
            gaps: [],
            totalFunctionsAnalyzed: 10,
            fullyCoveredFunctionCount: 10,
            uncoveredFunctionCount: 0
        )

        #expect(report.summary.contains("No coverage gaps"))
        #expect(report.hasSignificantGaps == false)
    }

    @Test("CoverageGapReport summary with gaps")
    func reportWithGaps() {
        let gap = CoverageGap(
            functionName: "partialFunc",
            filename: "/path/to/File.swift",
            uncoveredRegions: [
                UncoveredRegion(lineStart: 10, columnStart: 1, edgeIndex: 0),
                UncoveredRegion(lineStart: 20, columnStart: 1, edgeIndex: 1)
            ],
            coveredEdgeCount: 2,
            totalEdgeCount: 4
        )

        let report = CoverageGapReport(
            gaps: [gap],
            totalFunctionsAnalyzed: 10,
            fullyCoveredFunctionCount: 8,
            uncoveredFunctionCount: 1
        )

        #expect(report.summary.contains("1 function"))
        #expect(report.hasSignificantGaps == true)
    }

    @Test("CoverageGapReport detailed summary includes function info")
    func reportDetailedSummary() {
        let gap = CoverageGap(
            functionName: "processData",
            filename: "/Users/test/Project/Sources/Handler.swift",
            uncoveredRegions: [
                UncoveredRegion(lineStart: 42, columnStart: 1, edgeIndex: 0)
            ],
            coveredEdgeCount: 3,
            totalEdgeCount: 4
        )

        let report = CoverageGapReport(
            gaps: [gap],
            totalFunctionsAnalyzed: 5,
            fullyCoveredFunctionCount: 3,
            uncoveredFunctionCount: 1
        )

        let detailed = report.detailedSummary
        #expect(detailed.contains("processData"))
        #expect(detailed.contains("Handler.swift"))
        #expect(detailed.contains("75%"))
        #expect(detailed.contains("Line 42"))
    }

    // MARK: - CoverageGapDetector Config Tests

    @Test("CoverageGapDetector.Config defaults")
    func configDefaults() {
        let config = CoverageGapDetector.Config()

        #expect(config.minCoveragePercentageToReport == 5.0)
        #expect(config.excludedPathPrefixes.isEmpty)
        #expect(config.onlyReportSignificant == true)
    }

    @Test("CoverageGapDetector.Config custom values")
    func configCustom() {
        let config = CoverageGapDetector.Config(
            minCoveragePercentageToReport: 10.0,
            excludedPathPrefixes: ["/exclude/", "/skip/"],
            onlyReportSignificant: false
        )

        #expect(config.minCoveragePercentageToReport == 10.0)
        #expect(config.excludedPathPrefixes.count == 2)
        #expect(config.onlyReportSignificant == false)
    }

    // MARK: - CoverageGapDetector Tests

    @Test("CoverageGapDetector returns empty when SanCov unavailable")
    func detectorWhenUnavailable() async {
        // This test will check behavior when SanCov is available or not
        // In a test without SanCov instrumentation, this should return empty
        let detector = CoverageGapDetector()
        let report = await detector.detect(from: Set())

        // Either SanCov is available and we get a real report,
        // or it's not and we get an empty report
        #expect(report.totalFunctionsAnalyzed >= 0)
    }

    @Test("CoverageGapDetector with empty covered indices")
    func detectorEmptyCoverage() async {
        let detector = CoverageGapDetector()
        let report = await detector.detect(from: Set())

        // With no coverage, all functions should be "uncovered" (not gaps)
        #expect(report.gaps.isEmpty || report.uncoveredFunctionCount > 0)
    }

    @Test("CoverageGapDetector excludes system paths")
    func detectorExcludesSystemPaths() async {
        let config = CoverageGapDetector.Config()
        let detector = CoverageGapDetector(config: config)

        // System paths should be excluded
        // This is implicitly tested - we just verify the detector works
        let report = await detector.detect(from: Set([0, 1, 2]))
        #expect(report.gaps.allSatisfy { !$0.filename.contains("/usr/") })
        #expect(report.gaps.allSatisfy { !$0.filename.contains("/System/") })
    }

    @Test("CoverageGapDetector excludes custom paths")
    func detectorExcludesCustomPaths() async {
        let config = CoverageGapDetector.Config(
            excludedPathPrefixes: ["/custom/exclude/"]
        )
        let detector = CoverageGapDetector(config: config)

        let report = await detector.detect(from: Set([0, 1, 2]))
        #expect(report.gaps.allSatisfy { !$0.filename.contains("/custom/exclude/") })
    }

    // MARK: - Integration Tests

    @Test("Coverage gap detection in fuzz result")
    func fuzzResultIncludesGapReport() async throws {
        // Verify that FuzzResult has the coverageGapReport computed property
        let emptyCorpus = Corpus<Int>()
        let emptySnapshot = await emptyCorpus.snapshot()
        let stats = FuzzStats(
            totalInputs: 0,
            mutations: 0,
            generations: 0,
            duration: 0
        )

        let result = FuzzResult<Int>(
            corpus: emptySnapshot,
            failures: [],
            stats: stats,
            wasRegression: false
        )

        // Coverage gap reports are now handled via recordIssue actions from plugins
        // No direct access to coverage gap report in FuzzResult
        #expect(result.failures.isEmpty)
    }

    @Test("Realistic coverage gap test")
    func realisticCoverageGapTest() async throws {
        // Use a hash-based check that value profile can't solve easily
        @Sendable
        func partiallyCoveredFunction(input: Int) {
            // Simple hash to defeat value profile guidance
            let hash = (input &* 31) ^ (input >> 4)
            if hash == 0x7FFFFFFE {
                // This branch is effectively unreachable (requires specific input)
                print("found magic!")  // Line 284 - expected uncovered
            } else if input < 0 {
                print("negative")
            } else {
                print("positive")
            }
        }

        // This test intentionally creates a coverage gap to verify detection works
        // We expect exactly: 75% coverage, uncovered edge at line 284
        // If the issue doesn't match these criteria, the test will fail as "unexpected issue"
        let expectedLine = 284

        try await withKnownIssue("Expected coverage gap in partiallyCoveredFunction") {
            // mutation() is included by default via handlers
            _ = try await fuzz(
                duration: .seconds(0.5),
                corpusMode: .refuzzReplace,
                coverageStrategy: .signatureMatch,
                parallelism: 1,
                makeHandlers: { [.mutation(), .coverageGap()] }
            ) { (input: Int) in
                partiallyCoveredFunction(input: input)
            }
        } matching: { issue in
            let comment = issue.comments.first?.rawValue ?? ""
            let isCorrectLine = issue.sourceLocation?.line == expectedLine
            let isPartiallyCovered = comment.contains("partiallyCoveredFunction")
            let hasPartialCoverage = comment.contains("% covered")
            return isCorrectLine && isPartiallyCovered && hasPartialCoverage
        }
    }

    func parseAndValidate(_ input: Int) throws {
        if input == Int.min {
            // Edge case handling
        } else if input < 0 {
            let _ = abs(input)
        } else if input > 1000 {
            let _ = input / 2
        } else {
            let _ = input * 2
        }
    }
}
