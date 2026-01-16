import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

@Suite("Custom MutatorProviding Types")
struct CustomMutatorProvidingTests {

    @Test("Custom struct generates seed values")
    func testCustomMutatorProviding() async {
        let values = TestConfig.defaultMutator.seeds
        #expect(!values.isEmpty)
        print("TestConfig.defaultMutator.seeds generated \(values.count) values")
    }

    @Test("Custom struct mutations work")
    func testCustomMutation() async {
        let original = TestConfig(timeout: 10, retries: 3)
        let mutations = TestConfig.defaultMutator.mutate(original)

        #expect(!mutations.isEmpty)
        #expect(mutations.allSatisfy { $0 != original })
    }

    @Test("FuzzEngine works with custom types")
    func testFuzzEngineWithCustomType() async {
        let seenTimeouts = Synchronized(Set<Int>())
        let seenRetries = Synchronized(Set<Int>())

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 50) { (input: TestConfig) in
                await seenTimeouts.update { $0.insert(input.timeout) }
                await seenRetries.update { $0.insert(input.retries) }
            }
        }

        let timeoutCount = await seenTimeouts.value.count
        let retryCount = await seenRetries.value.count

        #expect(result.failures.isEmpty)
        #expect(timeoutCount > 1, "Should have seen multiple timeout values, got \(timeoutCount)")
        #expect(retryCount > 1, "Should have seen multiple retry values, got \(retryCount)")
    }
}


// MARK: - Codable MutatorProviding Types for Testing

struct TestConfig: MutatorProviding, Codable, Equatable, Sendable {
    let timeout: Int
    let retries: Int

    static var defaultMutator: AnyMutator<TestConfig> {
        // Generate a small set of test configurations
        let timeouts = Array(Int.defaultMutator.seeds.prefix(3))
        let retries = [0, 1, 3]

        var seeds: [TestConfig] = []
        for t in timeouts {
            for r in retries {
                seeds.append(TestConfig(timeout: t, retries: r))
            }
        }

        return AnyMutator(seeds: seeds) { value in
            var mutations: [TestConfig] = []
            for t in Int.defaultMutator.mutate(value.timeout).prefix(2) {
                mutations.append(TestConfig(timeout: t, retries: value.retries))
            }
            for r in Int.defaultMutator.mutate(value.retries).prefix(2) {
                mutations.append(TestConfig(timeout: value.timeout, retries: r))
            }
            return mutations
        }
    }
}
