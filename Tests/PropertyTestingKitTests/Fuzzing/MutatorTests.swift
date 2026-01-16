//
//  MutatorTests.swift
//  PropertyTestingKit
//
//  Tests for the Mutator protocol and built-in mutators.
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

// MARK: - Mutator Protocol Tests

@Suite("Mutator Protocol")
struct MutatorProtocolTests {
    @Test("AnyMutator type erases correctly")
    func anyMutatorTypeErases() async {
        let stringMutator = String.mutators(.empty)
        let erased = AnyMutator(stringMutator)

        #expect(!erased.seeds.isEmpty)
        #expect(erased.seeds.contains(""))
    }

    @Test("ComposedMutator combines seeds from all mutators")
    func composedMutatorCombinesSeeds() async {
        let composed = String.mutators(.empty, .whitespace)

        // Should have seeds from both strategies
        #expect(composed.seeds.contains(""))
        #expect(composed.seeds.contains(" "))
        #expect(composed.seeds.contains("\t"))
    }

    @Test("ComposedMutator combines mutations from all mutators")
    func composedMutatorCombinesMutations() async {
        let composed = String.mutators(.empty, .whitespace)
        let mutations = composed.mutate("test")

        // Should have mutations from both strategies
        #expect(mutations.count > 1)
    }

    @Test("MutatorProviding defaultMutator provides seeds and mutations")
    func defaultMutatorProvidesSeedsAndMutations() async {
        let mutator = Int.defaultMutator

        #expect(!mutator.seeds.isEmpty)
        #expect(!mutator.mutate(5).isEmpty)
    }

    @Test("SingleMutator works with custom seeds and mutate")
    func singleMutatorWorks() async {
        let mutator = SingleMutator<Int>(
            seeds: [1, 2, 3],
            mutate: { [$0 * 2] }
        )

        #expect(mutator.seeds == [1, 2, 3])
        #expect(mutator.mutate(5) == [10])
    }
}

// MARK: - String Mutator Tests

@Suite("String Mutators")
struct StringMutatorTests {
    @Test("PhoneNumber mutator has valid seeds")
    func phoneNumberSeeds() async {
        let mutator = String.mutators(.phoneNumbers)

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("555") }))
        #expect(mutator.seeds.contains(where: { $0.hasPrefix("+") }))
    }

    @Test("PhoneNumber mutator generates mutations")
    func phoneNumberMutations() async {
        let mutator = String.mutators(.phoneNumbers)
        let mutations = mutator.mutate("555-1234")

        #expect(!mutations.isEmpty)
        // Should include digit-only version
        #expect(mutations.contains(where: { $0.allSatisfy(\.isNumber) || $0.hasPrefix("+") }))
    }

    @Test("Email mutator has valid seeds")
    func emailSeeds() async {
        let mutator = String.mutators(.emails)

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("@") }))
    }

    @Test("Email mutator generates mutations")
    func emailMutations() async {
        let mutator = String.mutators(.emails)
        let mutations = mutator.mutate("test@example.com")

        #expect(!mutations.isEmpty)
        // Should include double @ version
        #expect(mutations.contains(where: { $0.contains("@@") }))
    }

    @Test("URL mutator has valid seeds")
    func urlSeeds() async {
        let mutator = String.mutators(.urls)

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.hasPrefix("http") }))
        #expect(mutator.seeds.contains(where: { $0.contains("javascript:") }))
    }

    @Test("SQL injection mutator has dangerous seeds")
    func sqlSeeds() async {
        let mutator = String.mutators(.sql)

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("DROP TABLE") }))
        #expect(mutator.seeds.contains(where: { $0.contains("OR") }))
    }

    @Test("SQL injection mutator generates attacks")
    func sqlMutations() async {
        let mutator = String.mutators(.sql)
        let mutations = mutator.mutate("admin")

        #expect(!mutations.isEmpty)
        #expect(mutations.contains(where: { $0.contains("'") }))
    }

    @Test("XSS mutator has script tags")
    func xssSeeds() async {
        let mutator = String.mutators(.xss)

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("<script>") }))
        #expect(mutator.seeds.contains(where: { $0.contains("onerror") }))
    }

    @Test("Unicode mutator has diverse characters")
    func unicodeSeeds() async {
        let mutator = String.mutators(.unicode)

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("😀") || $0.contains("Ω") }))
    }

    @Test("Whitespace mutator has various whitespace")
    func whitespaceSeeds() async {
        let mutator = String.mutators(.whitespace)

        #expect(mutator.seeds.contains(" "))
        #expect(mutator.seeds.contains("\t"))
        #expect(mutator.seeds.contains("\n"))
    }

    @Test("Empty string mutator includes empty")
    func emptySeeds() async {
        let mutator = String.mutators(.empty)

        #expect(mutator.seeds.contains(""))
    }

    @Test("Boundary mutator has length extremes")
    func boundarySeeds() async {
        let mutator = String.mutators(.boundaries)

        #expect(mutator.seeds.contains(""))
        #expect(mutator.seeds.contains("a"))
        #expect(mutator.seeds.contains(where: { $0.count >= 255 }))
    }

    @Test("Multiple strategies combine correctly")
    func multipleStrategies() async {
        let mutator = String.mutators(.sql, .xss)

        #expect(mutator.seeds.contains(where: { $0.contains("DROP") }))
        #expect(mutator.seeds.contains(where: { $0.contains("<script>") }))
    }
}

// MARK: - Int Mutator Tests

@Suite("Int Mutators")
struct IntMutatorTests {
    @Test("Boundary mutator has extremes")
    func boundarySeeds() async {
        let mutator = Int.mutators(.boundaries)

        #expect(mutator.seeds.contains(0))
        #expect(mutator.seeds.contains(1))
        #expect(mutator.seeds.contains(-1))
        #expect(mutator.seeds.contains(Int.max))
        #expect(mutator.seeds.contains(Int.min))
    }

    @Test("Boundary mutator generates useful mutations")
    func boundaryMutations() async {
        let mutator = Int.mutators(.boundaries)
        let mutations = mutator.mutate(100)

        #expect(mutations.contains(101)) // +1
        #expect(mutations.contains(99))  // -1
        #expect(mutations.contains(200)) // *2
        #expect(mutations.contains(50))  // /2
        #expect(mutations.contains(-100)) // negation
    }

    @Test("Port mutator has common ports")
    func portSeeds() async {
        let mutator = Int.mutators(.ports)

        #expect(mutator.seeds.contains(80))
        #expect(mutator.seeds.contains(443))
        #expect(mutator.seeds.contains(22))
        #expect(mutator.seeds.contains(8080))
        #expect(mutator.seeds.contains(65535))
    }

    @Test("HTTP status code mutator has all classes")
    func httpStatusSeeds() async {
        let mutator = Int.mutators(.httpStatusCodes)

        // 1xx informational
        #expect(mutator.seeds.contains(where: { $0 >= 100 && $0 < 200 }))
        // 2xx success
        #expect(mutator.seeds.contains(200))
        // 3xx redirect
        #expect(mutator.seeds.contains(301) || mutator.seeds.contains(302))
        // 4xx client error
        #expect(mutator.seeds.contains(404))
        // 5xx server error
        #expect(mutator.seeds.contains(500))
    }

    @Test("Negative mutator has negative values")
    func negativeSeeds() async {
        let mutator = Int.mutators(.negative)

        #expect(mutator.seeds.allSatisfy { $0 < 0 })
        #expect(mutator.seeds.contains(-1))
        #expect(mutator.seeds.contains(Int.min))
    }

    @Test("Powers mutator has powers of two")
    func powersSeeds() async {
        let mutator = Int.mutators(.powers)

        #expect(mutator.seeds.contains(1))
        #expect(mutator.seeds.contains(2))
        #expect(mutator.seeds.contains(4))
        #expect(mutator.seeds.contains(1024))
    }

    @Test("Multiple strategies combine correctly")
    func multipleStrategies() async {
        let mutator = Int.mutators(.boundaries, .ports)

        #expect(mutator.seeds.contains(Int.max))
        #expect(mutator.seeds.contains(443))
    }
}

// MARK: - Bool Mutator Tests

@Suite("Bool Mutator")
struct BoolMutatorTests {
    @Test("Bool mutator has both values")
    func boolSeeds() async {
        let mutator = Bool.mutator()

        #expect(mutator.seeds.contains(true))
        #expect(mutator.seeds.contains(false))
    }

    @Test("Bool mutator flips value")
    func boolMutations() async {
        let mutator = Bool.mutator()

        #expect(mutator.mutate(true) == [false])
        #expect(mutator.mutate(false) == [true])
    }
}

// MARK: - Double Mutator Tests

@Suite("Double Mutators")
struct DoubleMutatorTests {
    @Test("Boundary mutator has extremes")
    func boundarySeeds() async {
        let mutator = Double.mutators(.boundaries)

        #expect(mutator.seeds.contains(0.0))
        #expect(mutator.seeds.contains(1.0))
        #expect(mutator.seeds.contains(-1.0))
        #expect(mutator.seeds.contains(Double.leastNormalMagnitude))
    }

    @Test("Special mutator has special values")
    func specialSeeds() async {
        let mutator = Double.mutators(.special)

        #expect(mutator.seeds.contains(where: { $0.isNaN }))
        #expect(mutator.seeds.contains(Double.infinity))
        #expect(mutator.seeds.contains(-Double.infinity))
        #expect(mutator.seeds.contains(Double.pi))
    }

    @Test("Percentage mutator has 0-1 range values")
    func percentageSeeds() async {
        let mutator = Double.mutators(.percentages)

        #expect(mutator.seeds.contains(0.0))
        #expect(mutator.seeds.contains(0.5))
        #expect(mutator.seeds.contains(1.0))
        // Also has edge cases outside range
        #expect(mutator.seeds.contains(-0.1) || mutator.seeds.contains(1.1))
    }

    @Test("Multiple strategies combine correctly")
    func multipleStrategies() async {
        let mutator = Double.mutators(.boundaries, .special)

        #expect(mutator.seeds.contains(0.0))
        #expect(mutator.seeds.contains(where: { $0.isNaN }))
    }
}

// MARK: - FuzzEngine Integration Tests

@Suite("Mutator FuzzEngine Integration")
struct MutatorFuzzEngineTests {

    @Test("FuzzEngine uses mutator seeds")
    func engineUsesMutatorSeeds() async {
        let testedInputs = Synchronized([String]())

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let mutator = SingleMutator<String>(
                seeds: ["custom1", "custom2"],
                mutate: { _ in [] }
            )

            let config = FuzzEngine<String>.Config(
                maxDuration: .seconds(1)            )

            let engine = FuzzEngine<String>(mutators: mutator, config: config)
            _ = await engine.run { input in
                await testedInputs.update { $0.append(input) }
            }
        }

        let inputs = await testedInputs.value
        #expect(inputs.contains("custom1"))
        #expect(inputs.contains("custom2"))
    }

    @Test("FuzzEngine uses mutator with multiple seeds")
    func engineUsesMutatorWithMultipleSeeds() async {
        let testedInputs = Synchronized([String]())

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            // Use AnyMutator to test with multiple seeds
            let mutator = AnyMutator<String>(
                seeds: ["first", "second", "third"],
                mutate: { [$0 + "-mutated"] }
            )

            let config = FuzzEngine<String>.Config(
                maxDuration: .seconds(2)            )

            let engine = FuzzEngine<String>(mutators: mutator, config: config)
            _ = await engine.run { input in
                await testedInputs.update { $0.append(input) }
            }
        }

        // Should have tested all seeds
        let inputs = await testedInputs.value
        #expect(inputs.contains("first"))
        #expect(inputs.contains("second"))
        #expect(inputs.contains("third"))
    }
}

// MARK: - Public API Tests

@Suite("Mutator Public API")
struct MutatorPublicAPITests {

    @Test("fuzz(using:) accepts single mutator")
    func fuzzWithSingleMutator() async throws {
        let testedInputs = Synchronized([String]())

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        try await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
            // Use no-op file manager to avoid writing corpus to disk
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            let mutator = SingleMutator<String>(
                seeds: ["test1", "test2"],
                mutate: { _ in [] }
            )

            _ = try await fuzzWithMaxIterations(
                maxIterations: 50,
                using: mutator
            ) { (input: String) in
                await testedInputs.update { $0.append(input) }
            }
        }

        let inputs = await testedInputs.value
        #expect(inputs.contains("test1"))
        #expect(inputs.contains("test2"))
    }

    @Test("fuzz(using:) accepts built-in mutators")
    func fuzzWithBuiltInMutators() async throws {
        let testedInputs = Synchronized([String]())

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        try await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
            // Use no-op file manager to avoid writing corpus to disk
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            _ = try await fuzzWithMaxIterations(
                maxIterations: 50,
                using: String.mutators(.empty)
            ) { (input: String) in
                await testedInputs.update { $0.append(input) }
            }
        }

        let inputs = await testedInputs.value
        #expect(inputs.contains(""))
    }

    @Test("fuzz(using:) accepts multiple mutators for multiple inputs")
    func fuzzWithMultipleMutators() async throws {
        let testedInputs = Synchronized([(String, Int)]())

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        try await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            let stringMutator = SingleMutator<String>(
                seeds: ["hello", "world"],
                mutate: { [$0.uppercased()] }
            )
            let intMutator = SingleMutator<Int>(
                seeds: [1, 2, 3],
                mutate: { [$0 + 1] }
            )

            _ = try await fuzzWithMaxIterations(
                maxIterations: 50,
                using: stringMutator, intMutator
            ) { (str: String, num: Int) in
                await testedInputs.update { $0.append((str, num)) }
            }
        }

        // Should have cartesian product of seeds: hello/world × 1/2/3
        let inputs = await testedInputs.value
        let strings = Set(inputs.map(\.0))
        let ints = Set(inputs.map(\.1))

        #expect(strings.contains("hello"))
        #expect(strings.contains("world"))
        #expect(ints.contains(1))
        #expect(ints.contains(2))
        #expect(ints.contains(3))
    }

    @Test("fuzz(using:) with built-in mutators for multiple inputs")
    func fuzzWithMultipleBuiltInMutators() async throws {
        let testedInputs = Synchronized([(String, Int)]())

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        try await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            _ = try await fuzzWithMaxIterations(
                maxIterations: 50,
                using: String.mutators(.empty), Int.mutators(.boundaries)
            ) { (str: String, num: Int) in
                await testedInputs.update { $0.append((str, num)) }
            }
        }

        let inputs = await testedInputs.value
        let strings = Set(inputs.map(\.0))
        let ints = Set(inputs.map(\.1))

        // Empty mutator should include empty string
        #expect(strings.contains(""))

        // Boundaries mutator should include 0, 1, -1
        #expect(ints.contains(0))
        #expect(ints.contains(1))
        #expect(ints.contains(-1))
    }

    @Test("fuzz(using:) with composed mutator strategies for single input")
    func fuzzWithComposedStrategies() async throws {
        let testedInputs = Synchronized<[String]>([])

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        try await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
            // Use a seeded RNG for deterministic test behavior
            $0.random = RandomNumberGeneratorClient { SeededRandomNumberGenerator(seed: 42) }
        } operation: {
            // Compose multiple strategies for a single String input
            // Need more iterations to reliably generate cross-strategy mutations
            _ = try await fuzzWithMaxIterations(
                maxIterations: 200,
                using: String.mutators(.empty, .sql, .xss)
            ) { (input: String) in
                await testedInputs.update { $0.append(input) }
            }
        }

        // Get all values for assertions
        let inputs = await testedInputs.value

        // Should have seeds from all three strategies
        // Empty strategy
        #expect(inputs.contains(""))

        // SQL strategy seeds - look for SQL injection patterns
        #expect(inputs.contains(where: { $0.contains("DROP TABLE") || $0.contains("OR") }))

        // XSS strategy seeds - look for script tags
        #expect(inputs.contains(where: { $0.contains("<script>") || $0.contains("onerror") }))

        // Cross-strategy mutations: SQL mutations applied to XSS seeds
        // SQL mutator adds "'" prefix/suffix, SQL keywords, or comment suffixes
        // Applied to XSS seeds
        #expect(
            inputs.contains(where: {
                // XSS seed with SQL quote prefix (any XSS pattern)
                ($0.hasPrefix("'") && ($0.contains("<") || $0.contains("javascript:") || $0.contains("alert") || $0.contains("onerror"))) ||
                // XSS seed with SQL keyword/pattern suffix
                (($0.contains("<script>") || $0.contains("onerror") || $0.contains("javascript:")) &&
                 ($0.contains("/**/") || $0.contains("; DROP") || $0.contains(" OR ") || $0.contains("'--")))
            }),
            "SQL mutations should be applied to XSS seeds"
        )

        // Cross-strategy mutations: XSS mutations applied to SQL seeds
        // XSS mutator wraps in <script> tags or adds event handlers
        // Applied to SQL seeds
        #expect(
            inputs.contains(where: {
                // SQL content wrapped in script tags (any SQL keyword/pattern)
                ($0.contains("<script>") && ($0.contains("DROP") || $0.contains("SELECT") || $0.contains("EXEC") || $0.contains("OR ") || $0.contains("OR(") || $0.contains("SLEEP") || $0.contains("WAITFOR") || $0.contains("'--"))) ||
                // SQL content in img onerror
                ($0.contains("onerror=") && ($0.contains("DROP") || $0.contains("SELECT") || $0.contains("UNION") || $0.contains("OR ") || $0.contains("SLEEP")))
            }),
            "XSS mutations should be applied to SQL seeds"
        )
    }
}
