import Testing
import PropertyTestingKit

/// Tests for coverage APIs using UserService
@Suite("UserService Coverage Tests")
struct UserServiceCoverageTests {

    @Test("Compare createUser vs updateUser coverage with SanCov")
    func compareUserServiceMethods() async {
        let db = MockDatabase()
        let service = UserService(db: db)

        // Measure createUser with task-isolated SanCov
        let createCoverage = measureSanCovSourceCoverage {
            _ = service.createUser(id: "test1", name: "Alice")
        }

        // Measure updateUser (on existing user)
        _ = service.createUser(id: "test2", name: "Bob")
        let updateCoverage = measureSanCovSourceCoverage {
            _ = service.updateUser(id: "test2", name: "Bob Updated")
        }

        guard let createCoverage = createCoverage, let updateCoverage = updateCoverage else {
            Issue.record("SanCov not available")
            return
        }

        print("\n=== createUser Coverage ===")
        print("Covered edges: \(createCoverage.coveredCount)")
        print("Covered functions: \(createCoverage.coveredFunctions.count)")
        let createUserFns = createCoverage.coveredFunctions.filter { $0.contains("createUser") }
        for fn in createUserFns {
            print("  Function: \(fn)")
        }

        print("\n=== updateUser Coverage ===")
        print("Covered edges: \(updateCoverage.coveredCount)")
        print("Covered functions: \(updateCoverage.coveredFunctions.count)")
        let updateUserFns = updateCoverage.coveredFunctions.filter { $0.contains("updateUser") }
        for fn in updateUserFns {
            print("  Function: \(fn)")
        }

        // Both should have coverage
        #expect(createCoverage.coveredCount > 0, "createUser should have coverage")
        #expect(updateCoverage.coveredCount > 0, "updateUser should have coverage")
    }

    @Test("Check all UserService functions in coverage mapping")
    func checkUserServiceInCoverageMapping() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let coverage = reader.resolveCoverage()

        print("\n=== All UserService Functions in Coverage Mapping ===")
        let userServiceFns = coverage.functions.filter {
            $0.name.contains("UserService")
        }

        for fn in userServiceFns {
            print("\nFunction: \(fn.name)")
            print("  Execution count: \(fn.executionCount)")
            print("  Regions: \(fn.regions.count)")
        }

        #expect(userServiceFns.count > 0, "Should have UserService functions")
    }

    @Test("Filter coverage to project files only")
    func filterCoverageToProject() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let fullCoverage = reader.resolveCoverage()

        // Filter to only files in this project
        let projectPath = "/Users/alex.reilly/Documents/Swift/PropertyTestingKit"
        let projectCoverage = fullCoverage.filtered(byPathPrefix: projectPath)

        print("\n=== Coverage Filtering ===")
        print("Full coverage: \(fullCoverage.functions.count) functions, \(fullCoverage.sourceFiles.count) files")
        print("Project coverage: \(projectCoverage.functions.count) functions, \(projectCoverage.sourceFiles.count) files")

        // Project coverage should be smaller (excludes system libraries)
        #expect(projectCoverage.functions.count <= fullCoverage.functions.count)
        #expect(projectCoverage.functions.count > 0, "Should have project functions")
    }

    @Test("SanCov source coverage provides function names")
    func sanCovSourceCoverageProvidesFunctionNames() async {
        let db = MockDatabase()
        let service = UserService(db: db)

        let coverage = measureSanCovSourceCoverage {
            _ = service.createUser(id: "filter1", name: "Test")
        }

        guard let coverage = coverage else {
            Issue.record("SanCov not available")
            return
        }

        print("\n=== SanCov Source Coverage ===")
        print("Covered functions: \(coverage.coveredFunctions.count)")
        print("Covered files: \(coverage.coveredFiles.count)")

        // Should have some coverage
        #expect(coverage.coveredCount > 0, "Should have covered edges")

        // Should have function names if PCs are available
        if SanCovCounters.pcsAvailable {
            #expect(!coverage.coveredFunctions.isEmpty, "Should have function names")

            // Look for UserService-related functions
            let userServiceFns = coverage.coveredFunctions.filter { $0.contains("UserService") || $0.contains("createUser") }
            #expect(!userServiceFns.isEmpty, "Should have UserService functions in coverage")
        }
    }

    @Test("All function names should be demangled")
    func allNamesShouldBeDemangled() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let coverage = reader.resolveCoverage()

        var mangledCount = 0
        var demangledCount = 0
        var mangledExamples: [String] = []

        for fn in coverage.functions {
            let name = fn.name

            // Check if name still looks mangled
            let looksMangled = name.hasPrefix("$s") ||
                               name.hasPrefix("_$s") ||
                               name.hasPrefix("_Z") ||
                               name.contains(":$s") ||
                               name.contains(":_$s") ||
                               name.contains(":_Z")

            if looksMangled {
                mangledCount += 1
                if mangledExamples.count < 5 {
                    mangledExamples.append(name)
                }
            } else {
                demangledCount += 1
            }
        }

        print("\n=== Demangling Statistics ===")
        print("Total functions: \(coverage.functions.count)")
        print("Demangled: \(demangledCount)")
        print("Still mangled: \(mangledCount)")

        if !mangledExamples.isEmpty {
            print("\nMangled examples that need attention:")
            for example in mangledExamples {
                print("  \(example)")
            }
        }

        // All names should be demangled
        #expect(mangledCount == 0, "Found \(mangledCount) functions with mangled names")
    }

    @Test("Demangling handles various symbol types")
    func demanglingHandlesVariousTypes() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let coverage = reader.resolveCoverage()

        // Categorize demangled names
        var swiftMethods: [String] = []
        var swiftClosures: [String] = []
        var swiftGetters: [String] = []
        var cppFunctions: [String] = []
        var other: [String] = []

        for fn in coverage.functions {
            let name = fn.name

            if name.contains("closure #") || name.contains("implicit closure") {
                swiftClosures.append(name)
            } else if name.contains(".getter :") || name.contains(".setter :") {
                swiftGetters.append(name)
            } else if name.contains("::") {
                cppFunctions.append(name)
            } else if name.contains(".") && (name.contains("(") || name.contains(" -> ")) {
                swiftMethods.append(name)
            } else {
                other.append(name)
            }
        }

        print("\n=== Demangled Name Categories ===")
        print("Swift methods: \(swiftMethods.count)")
        print("Swift closures: \(swiftClosures.count)")
        print("Swift getters/setters: \(swiftGetters.count)")
        print("C++ functions: \(cppFunctions.count)")
        print("Other: \(other.count)")

        // We should have at least some Swift methods
        #expect(swiftMethods.count > 0, "Should have Swift methods")
    }

    @Test("SanCov direct counter inspection")
    func inspectSanCovCountersDirectly() async {
        guard SanCovCounters.isAvailable else {
            Issue.record("SanCov not available")
            return
        }

        let db = MockDatabase()
        let service = UserService(db: db)

        // Reset and measure createUser
        SanCovCounters.reset()
        let created = service.createUser(id: "direct1", name: "Test")
        #expect(created == true)

        let createCount = SanCovCounters.currentCoveredCount
        print("\n=== Edges covered by createUser: \(createCount) ===")

        // Reset and measure updateUser
        SanCovCounters.reset()
        let updated = service.updateUser(id: "direct1", name: "Updated")
        #expect(updated == true)

        let updateCount = SanCovCounters.currentCoveredCount
        print("=== Edges covered by updateUser: \(updateCount) ===")

        // Both should cover some code
        #expect(createCount > 0, "createUser should cover edges")
        #expect(updateCount > 0, "updateUser should cover edges")
    }
}
