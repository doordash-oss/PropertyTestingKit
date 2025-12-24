import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

@Suite("Custom Fuzzable Types")
struct CustomFuzzableTests {

    @Test("Custom struct generates fuzz values")
    func testCustomFuzzable() async {
        let values = TestConfig.fuzz
        #expect(!values.isEmpty)
        print("TestConfig.fuzz generated \(values.count) values")
    }

    @Test("Custom struct mutations work")
    func testCustomMutation() async {
        let original = TestConfig(timeout: 10, retries: 3)
        let mutations = original.mutate()

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
            let config = FuzzEngine<TestConfig>.Config(
                maxIterations: 30,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<TestConfig>(config: config, corpusDirectory: nil)

            return await engine.run { input in
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


// MARK: - Codable Fuzzable Types for Testing

struct TestConfig: Fuzzable, Codable, Equatable, Sendable {
    let timeout: Int
    let retries: Int

    static var fuzz: [TestConfig] {
        // Generate a small set of test configurations
        let timeouts = Array(Int.fuzz.prefix(3))
        let retries = [0, 1, 3]

        var configs: [TestConfig] = []
        for t in timeouts {
            for r in retries {
                configs.append(TestConfig(timeout: t, retries: r))
            }
        }
        return configs
    }

    func mutate() -> [TestConfig] {
        var mutations: [TestConfig] = []
        for t in timeout.mutate().prefix(2) {
            mutations.append(TestConfig(timeout: t, retries: retries))
        }
        for r in retries.mutate().prefix(2) {
            mutations.append(TestConfig(timeout: timeout, retries: r))
        }
        return mutations
    }
}
