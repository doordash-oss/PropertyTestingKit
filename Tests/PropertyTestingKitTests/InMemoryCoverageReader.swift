import Testing
import PropertyTestingKit
import Foundation

// MARK: - InMemoryCoverageReader Tests

@Suite("InMemoryCoverageReader API")
struct InMemoryCoverageReaderTests {

    @Test("InMemoryCoverageReader loads from current process")
    func testLoadFromCurrentProcess() throws {
        // Print diagnostic info
        let execPath = ProcessInfo.processInfo.arguments[0]
        print("Test executable path: \(execPath)")

        do {
            let reader = try InMemoryCoverageReader.loadFromCurrentProcess()

            // Should have some functions
            #expect(reader.functionCount > 0)
            print("Loaded \(reader.functionCount) functions from coverage mapping")

            // Should have some source files
            let files = reader.sourceFiles
            #expect(files.count > 0)
            print("Found \(files.count) source files")
        } catch {
            // Skip test if coverage mapping isn't available
            // This can happen if the binary wasn't built with proper coverage flags
            print("Skipping test: \(error)")
            print("Note: In-memory coverage requires binary to have __llvm_covmap section")
        }
    }

    @Test("InMemoryCoverageReader resolves coverage")
    func testResolveCoverage() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let db = MockDatabase()

        // Exercise some code
        db.write(key: "test", value: "value")
        _ = db.read(key: "test")

        // Resolve coverage
        let coverage = reader.resolveCoverage()

        #expect(coverage.functions.count > 0)
        #expect(coverage.sourceFiles.count > 0)

        // Print some coverage details
        let executedRegions = coverage.executedRegions
        print("Executed \(executedRegions.count) regions")

        // Look for coverage in this test file
        let thisFileCoverage = coverage.coverage(for: "PerTestCoverageDemo.swift")
        print("Found \(thisFileCoverage.count) regions in this file")
    }

    @Test("SanCov shows different code paths")
    func testDifferentCodePaths() async {
        let db = MockDatabase()

        // Check if SanCov is available
        guard SanCovCounters.isAvailable else {
            print("SanCov counters not available - skipping test")
            return
        }
        print("Total edges: \(SanCovCounters.totalEdgeCount)")

        // First measurement - write only (task-isolated)
        let writeCoverage = measureSanCovSourceCoverage {
            db.write(key: "a", value: "1")
        }

        // Second measurement - read only (task-isolated)
        let readCoverage = measureSanCovSourceCoverage {
            _ = db.read(key: "a")
        }

        guard let writeCoverage = writeCoverage, let readCoverage = readCoverage else {
            Issue.record("SanCov coverage measurement failed")
            return
        }

        // Print some debug info
        print("Write path covered \(writeCoverage.coveredCount) edges")
        print("Read path covered \(readCoverage.coveredCount) edges")
        print("Write path functions: \(writeCoverage.coveredFunctions.count)")
        print("Read path functions: \(readCoverage.coveredFunctions.count)")

        // Both should have coverage
        #expect(writeCoverage.coveredCount > 0, "Write path should have coverage")
        #expect(readCoverage.coveredCount > 0, "Read path should have coverage")
    }
}
