import Testing
import PropertyTestingKit

/// Diagnostic test to investigate why UserService.createUser shows 0 coverage
/// while updateUser shows 1 call in Xcode.
@Suite("UserService Coverage Diagnostics")
struct UserServiceCoverageDiagnostics {

    @Test("Compare createUser vs updateUser coverage")
    func compareUserServiceMethods() throws {
        let db = MockDatabase()
        let service = UserService(db: db)

        // Measure createUser
        let (createResult, createCoverage) = try measureSourceCoverage {
            return service.createUser(id: "test1", name: "Alice")
        }

        // Measure updateUser (on existing user)
        _ = service.createUser(id: "test2", name: "Bob")
        let (updateResult, updateCoverage) = try measureSourceCoverage {
            return service.updateUser(id: "test2", name: "Bob Updated")
        }

        print("\n=== createUser Coverage ===")
        print("Result: \(createResult)")
        let createUserFns = createCoverage.functions.filter { $0.name.contains("createUser") }
        for fn in createUserFns {
            print("Function: \(fn.name)")
            print("  executionCount: \(fn.executionCount)")
            for region in fn.regions {
                print("  Region \(region.lineStart):\(region.columnStart)-\(region.lineEnd):\(region.columnEnd) = \(region.executionCount)")
            }
        }

        print("\n=== updateUser Coverage ===")
        print("Result: \(updateResult)")
        let updateUserFns = updateCoverage.functions.filter { $0.name.contains("updateUser") }
        for fn in updateUserFns {
            print("Function: \(fn.name)")
            print("  executionCount: \(fn.executionCount)")
            for region in fn.regions {
                print("  Region \(region.lineStart):\(region.columnStart)-\(region.lineEnd):\(region.columnEnd) = \(region.executionCount)")
            }
        }

        // Also check raw counter changes
        print("\n=== Raw Counter Analysis ===")
        guard let before = CoverageCounters.snapshot() else {
            print("No counters available")
            return
        }

        _ = service.createUser(id: "test3", name: "Charlie")

        guard let afterCreate = CoverageCounters.snapshot() else {
            print("No counters available after create")
            return
        }

        let createDiff = afterCreate.difference(from: before)
        print("createUser changed \(createDiff.changedCount) counters")
        print("createUser newly executed \(createDiff.executedRegions) regions")
        print("Changed indices: \(createDiff.changedIndices.prefix(20))...")

        _ = service.updateUser(id: "test3", name: "Charlie Updated")

        guard let afterUpdate = CoverageCounters.snapshot() else {
            print("No counters available after update")
            return
        }

        let updateDiff = afterUpdate.difference(from: afterCreate)
        print("\nupdateUser changed \(updateDiff.changedCount) counters")
        print("updateUser newly executed \(updateDiff.executedRegions) regions")
        print("Changed indices: \(updateDiff.changedIndices.prefix(20))...")

        // Basic assertions
        #expect(createResult == true)
        #expect(updateResult == true)
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
            print("\nFunction: \(fn.name)")  // Use demangled name!
            print("  Execution count: \(fn.executionCount)")
            print("  Regions: \(fn.regions.count)")
            for region in fn.regions {
                print("    \(region.lineStart):\(region.columnStart)-\(region.lineEnd):\(region.columnEnd) = \(region.executionCount)")
            }
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

        // Show some demangled function names
        print("\n=== Sample Demangled Names ===")
        for fn in projectCoverage.functions.prefix(5) {
            print("  \(fn.name)")
        }
    }

    @Test("measureSourceCoverage filters dependencies by default")
    func measureSourceCoverageFiltersDefault() throws {
        let db = MockDatabase()
        let service = UserService(db: db)

        // Default behavior: excludes dependencies
        let (_, filteredCoverage) = try measureSourceCoverage {
            return service.createUser(id: "filter1", name: "Test")
        }

        // With includeAllFiles: includes everything
        let (_, fullCoverage) = try measureSourceCoverage(includeAllFiles: true) {
            return service.createUser(id: "filter2", name: "Test2")
        }

        print("\n=== measureSourceCoverage Default Filtering ===")
        print("Default (filtered): \(filteredCoverage.functions.count) functions, \(filteredCoverage.sourceFiles.count) files")
        print("includeAllFiles=true: \(fullCoverage.functions.count) functions, \(fullCoverage.sourceFiles.count) files")

        // Filtered coverage should only contain project files
        for file in filteredCoverage.sourceFiles {
            #expect(!file.hasPrefix("/usr"), "Should not include /usr: \(file)")
            #expect(!file.hasPrefix("/System"), "Should not include /System: \(file)")
            #expect(!file.contains("/.build/checkouts/"), "Should not include dependencies: \(file)")
        }

        // Both should have some coverage
        #expect(filteredCoverage.functions.count > 0, "Should have filtered functions")
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
            // Swift mangled: starts with $s or contains :$s
            // C++ mangled: starts with _Z or contains :_Z
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
                // C++ uses :: for namespaces/classes
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

        // Show examples of each
        if !swiftMethods.isEmpty {
            print("\nSwift method examples:")
            for m in swiftMethods.prefix(3) { print("  \(m)") }
        }
        if !swiftClosures.isEmpty {
            print("\nSwift closure examples:")
            for c in swiftClosures.prefix(3) { print("  \(c)") }
        }
        if !cppFunctions.isEmpty {
            print("\nC++ function examples:")
            for c in cppFunctions.prefix(3) { print("  \(c)") }
        }

        // We should have at least some Swift methods
        #expect(swiftMethods.count > 0, "Should have Swift methods")
    }

    @Test("Direct counter inspection for UserService methods")
    func inspectCountersDirectly() throws {
        // Get a fresh snapshot
        guard let snapshot1 = CoverageCounters.snapshot() else {
            Issue.record("No counters")
            return
        }

        let db = MockDatabase()
        let service = UserService(db: db)

        // Call createUser
        let created = service.createUser(id: "direct1", name: "Test")
        #expect(created == true)

        guard let snapshot2 = CoverageCounters.snapshot() else {
            Issue.record("No counters after create")
            return
        }

        // Find which counters changed
        var createChanges: [(index: Int, before: UInt64, after: UInt64)] = []
        for i in 0..<min(snapshot1.count, snapshot2.count) {
            if snapshot2.counters[i] != snapshot1.counters[i] {
                createChanges.append((i, snapshot1.counters[i], snapshot2.counters[i]))
            }
        }

        print("\n=== Counters changed by createUser ===")
        print("Total changed: \(createChanges.count)")
        for change in createChanges.prefix(30) {
            print("  [\(change.index)]: \(change.before) -> \(change.after)")
        }

        // Now call updateUser
        let updated = service.updateUser(id: "direct1", name: "Updated")
        #expect(updated == true)

        guard let snapshot3 = CoverageCounters.snapshot() else {
            Issue.record("No counters after update")
            return
        }

        var updateChanges: [(index: Int, before: UInt64, after: UInt64)] = []
        for i in 0..<min(snapshot2.count, snapshot3.count) {
            if snapshot3.counters[i] != snapshot2.counters[i] {
                updateChanges.append((i, snapshot2.counters[i], snapshot3.counters[i]))
            }
        }

        print("\n=== Counters changed by updateUser ===")
        print("Total changed: \(updateChanges.count)")
        for change in updateChanges.prefix(30) {
            print("  [\(change.index)]: \(change.before) -> \(change.after)")
        }

        // Check overlap
        let createIndices = Set(createChanges.map { $0.index })
        let updateIndices = Set(updateChanges.map { $0.index })
        let overlap = createIndices.intersection(updateIndices)
        print("\n=== Overlap ===")
        print("Counters changed by both: \(overlap.sorted().prefix(20))...")
    }
}
