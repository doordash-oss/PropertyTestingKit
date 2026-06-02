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

//  Tests for the Mutator struct and built-in mutators.
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

// MARK: - Mutator Struct Tests

@Suite("Mutator Struct")
struct MutatorStructTests {
    @Test("Mutator stores seeds and closures correctly")
    func mutatorStoresSeedsAndClosures() async {
        let mutator = Mutator<String>(
            seeds: ["test1", "test2"],
            mutate: { [$0.uppercased()] },
            generate: { _ in "generated" }
        )

        #expect(mutator.seeds == ["test1", "test2"])
        #expect(mutator.mutate("hello") == ["HELLO"])
        var rng = FastRNG()
        #expect(mutator.generate(&rng) == "generated")
    }

    @Test("Mutator.compose combines seeds from all mutators")
    func composeCommbinesSeeds() async {
        let composed = Mutator.compose([emptyStringMutator, whitespaceMutator])

        // Should have seeds from both strategies
        #expect(composed.seeds.contains(""))
        #expect(composed.seeds.contains(" "))
        #expect(composed.seeds.contains("\t"))
    }

    @Test("Mutator.compose combines mutations from all mutators")
    func composeCombinesMutations() async {
        let composed = Mutator.compose([emptyStringMutator, whitespaceMutator])
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

    @Test("Mutator works with custom seeds and mutate")
    func mutatorWorksWithCustomSeedsAndMutate() async {
        let mutator = Mutator<Int>(
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
        let mutator = phoneNumberMutator

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("555") }))
        #expect(mutator.seeds.contains(where: { $0.hasPrefix("+") }))
    }

    @Test("PhoneNumber mutator generates mutations")
    func phoneNumberMutations() async {
        let mutator = phoneNumberMutator
        let mutations = mutator.mutate("555-1234")

        #expect(!mutations.isEmpty)
        // Should include digit-only version
        #expect(mutations.contains(where: { $0.allSatisfy(\.isNumber) || $0.hasPrefix("+") }))
    }

    @Test("Email mutator has valid seeds")
    func emailSeeds() async {
        let mutator = emailMutator

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("@") }))
    }

    @Test("Email mutator generates mutations")
    func emailMutations() async {
        let mutator = emailMutator
        let mutations = mutator.mutate("test@example.com")

        #expect(!mutations.isEmpty)
        // Should include double @ version
        #expect(mutations.contains(where: { $0.contains("@@") }))
    }

    @Test("URL mutator has valid seeds")
    func urlSeeds() async {
        let mutator = urlMutator

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.hasPrefix("http") }))
        #expect(mutator.seeds.contains(where: { $0.contains("javascript:") }))
    }

    @Test("SQL injection mutator has dangerous seeds")
    func sqlSeeds() async {
        let mutator = sqlInjectionMutator

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("DROP TABLE") }))
        #expect(mutator.seeds.contains(where: { $0.contains("OR") }))
    }

    @Test("SQL injection mutator generates attacks")
    func sqlMutations() async {
        let mutator = sqlInjectionMutator
        let mutations = mutator.mutate("admin")

        #expect(!mutations.isEmpty)
        #expect(mutations.contains(where: { $0.contains("'") }))
    }

    @Test("XSS mutator has script tags")
    func xssSeeds() async {
        let mutator = xssMutator

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("<script>") }))
        #expect(mutator.seeds.contains(where: { $0.contains("onerror") }))
    }

    @Test("Unicode mutator has diverse characters")
    func unicodeSeeds() async {
        let mutator = unicodeMutator

        #expect(!mutator.seeds.isEmpty)
        #expect(mutator.seeds.contains(where: { $0.contains("😀") || $0.contains("Ω") }))
    }

    @Test("Whitespace mutator has various whitespace")
    func whitespaceSeeds() async {
        let mutator = whitespaceMutator

        #expect(mutator.seeds.contains(" "))
        #expect(mutator.seeds.contains("\t"))
        #expect(mutator.seeds.contains("\n"))
    }

    @Test("Empty string mutator includes empty")
    func emptySeeds() async {
        let mutator = emptyStringMutator

        #expect(mutator.seeds.contains(""))
    }

    @Test("Boundary mutator has length extremes")
    func boundarySeeds() async {
        let mutator = stringBoundaryMutator

        #expect(mutator.seeds.contains(""))
        #expect(mutator.seeds.contains("a"))
        #expect(mutator.seeds.contains(where: { $0.count >= 255 }))
    }

    @Test("Multiple strategies combine correctly")
    func multipleStrategies() async {
        let mutator = Mutator.compose([sqlInjectionMutator, xssMutator])

        #expect(mutator.seeds.contains(where: { $0.contains("DROP") }))
        #expect(mutator.seeds.contains(where: { $0.contains("<script>") }))
    }
}

// MARK: - Int Mutator Tests

@Suite("Int Mutators")
struct IntMutatorTests {
    @Test("Boundary mutator has extremes")
    func boundarySeeds() async {
        let mutator = intBoundaryMutator

        #expect(mutator.seeds.contains(0))
        #expect(mutator.seeds.contains(1))
        #expect(mutator.seeds.contains(-1))
        #expect(mutator.seeds.contains(Int.max))
        #expect(mutator.seeds.contains(Int.min))
    }

    @Test("Boundary mutator generates useful mutations")
    func boundaryMutations() async {
        let mutator = intBoundaryMutator
        let mutations = mutator.mutate(100)

        #expect(mutations.contains(101)) // +1
        #expect(mutations.contains(99))  // -1
        #expect(mutations.contains(200)) // *2
        #expect(mutations.contains(50))  // /2
        #expect(mutations.contains(-100)) // negation
    }

    @Test("Port mutator has common ports")
    func portSeeds() async {
        let mutator = portMutator

        #expect(mutator.seeds.contains(80))
        #expect(mutator.seeds.contains(443))
        #expect(mutator.seeds.contains(22))
        #expect(mutator.seeds.contains(8080))
        #expect(mutator.seeds.contains(65535))
    }

    @Test("HTTP status code mutator has all classes")
    func httpStatusSeeds() async {
        let mutator = httpStatusCodeMutator

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
        let mutator = negativeIntMutator

        #expect(mutator.seeds.allSatisfy { $0 < 0 })
        #expect(mutator.seeds.contains(-1))
        #expect(mutator.seeds.contains(Int.min))
    }

    @Test("Powers mutator has powers of two")
    func powersSeeds() async {
        let mutator = powerOfTwoMutator

        #expect(mutator.seeds.contains(1))
        #expect(mutator.seeds.contains(2))
        #expect(mutator.seeds.contains(4))
        #expect(mutator.seeds.contains(1024))
    }

    @Test("Multiple strategies combine correctly")
    func multipleStrategies() async {
        let mutator = Mutator.compose([intBoundaryMutator, portMutator])

        #expect(mutator.seeds.contains(Int.max))
        #expect(mutator.seeds.contains(443))
    }
}

// MARK: - Bool Mutator Tests

@Suite("Bool Mutator")
struct BoolMutatorTests {
    @Test("Bool mutator has both values")
    func boolSeeds() async {
        let mutator = Bool.defaultMutator

        #expect(mutator.seeds.contains(true))
        #expect(mutator.seeds.contains(false))
    }

    @Test("Bool mutator flips value")
    func boolMutations() async {
        let mutator = Bool.defaultMutator

        #expect(mutator.mutate(true) == [false])
        #expect(mutator.mutate(false) == [true])
    }
}

// MARK: - Double Mutator Tests

@Suite("Double Mutators")
struct DoubleMutatorTests {
    @Test("Boundary mutator has extremes")
    func boundarySeeds() async {
        let mutator = doubleBoundaryMutator

        #expect(mutator.seeds.contains(0.0))
        #expect(mutator.seeds.contains(1.0))
        #expect(mutator.seeds.contains(-1.0))
        #expect(mutator.seeds.contains(Double.leastNormalMagnitude))
    }

    @Test("Special mutator has special values")
    func specialSeeds() async {
        let mutator = specialDoubleMutator

        #expect(mutator.seeds.contains(where: { $0.isNaN }))
        #expect(mutator.seeds.contains(Double.infinity))
        #expect(mutator.seeds.contains(-Double.infinity))
        #expect(mutator.seeds.contains(Double.pi))
    }

    @Test("Percentage mutator has 0-1 range values")
    func percentageSeeds() async {
        let mutator = percentageMutator

        #expect(mutator.seeds.contains(0.0))
        #expect(mutator.seeds.contains(0.5))
        #expect(mutator.seeds.contains(1.0))
        // Also has edge cases outside range
        #expect(mutator.seeds.contains(-0.1) || mutator.seeds.contains(1.1))
    }

    @Test("Multiple strategies combine correctly")
    func multipleStrategies() async {
        let mutator = Mutator.compose([doubleBoundaryMutator, specialDoubleMutator])

        #expect(mutator.seeds.contains(0.0))
        #expect(mutator.seeds.contains(where: { $0.isNaN }))
    }
}

// MARK: - FuzzEngine Integration Tests

@Suite("Mutator FuzzEngine Integration")
struct MutatorFuzzEngineTests {

    @Test("FuzzEngine uses mutator seeds")
    func engineUsesMutatorSeeds() async throws {
        let testedInputs = Synchronized([String]())

        let mutator = Mutator<String>(
            seeds: ["custom1", "custom2"],
            mutate: { _ in [] }
        )

        // .refuzzReplace prevents stale on-disk corpus from short-circuiting
        // the test into single-entry regression mode.
        _ = try await fuzzWithMaxIterations(
            maxIterations: 2,
            using: mutator,
            persistence: .replace,
            coverageStrategy: .alwaysInteresting
        ) { input in
            await testedInputs.update { $0.append(input) }
        }

        let inputs = await testedInputs.value
        #expect(inputs.contains("custom1"))
        #expect(inputs.contains("custom2"))
    }

    @Test("FuzzEngine uses mutator with multiple seeds")
    func engineUsesMutatorWithMultipleSeeds() async throws {
        let testedInputs = Synchronized([String]())

        let mutator = Mutator<String>(
            seeds: ["first", "second", "third"],
            mutate: { [$0 + "-mutated"] }
        )

        // .refuzzReplace prevents stale on-disk corpus from short-circuiting
        // the test into single-entry regression mode.
        _ = try await fuzzWithMaxIterations(
            maxIterations: 3,
            using: mutator,
            persistence: .replace,
            coverageStrategy: .alwaysInteresting
        ) { input in
            await testedInputs.update { $0.append(input) }
        }

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

        try await withDependencies {
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
            let mutator = Mutator<String>(
                seeds: ["test1", "test2"],
                mutate: { _ in [] }
            )

            _ = try await fuzzWithMaxIterations(
                maxIterations: 50,
                using: mutator,
                coverageStrategy: .alwaysInteresting
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

        try await withDependencies {
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
                using: emptyStringMutator,
                coverageStrategy: .alwaysInteresting
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

        try await withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            let stringMutator = Mutator<String>(
                seeds: ["hello", "world"],
                mutate: { [$0.uppercased()] }
            )
            let intMutator = Mutator<Int>(
                seeds: [1, 2, 3],
                mutate: { [$0 + 1] }
            )

            _ = try await fuzzWithMaxIterations(
                maxIterations: 50,
                using: stringMutator, intMutator,
                coverageStrategy: .alwaysInteresting
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

        try await withDependencies {
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
                using: emptyStringMutator, intBoundaryMutator,
                coverageStrategy: .alwaysInteresting
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
}
