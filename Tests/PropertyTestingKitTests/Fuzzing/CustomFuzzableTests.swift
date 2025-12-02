import Testing
import Foundation
import PropertyTestingKit

@Suite("Custom Fuzzable Types", .serialized)
struct CustomFuzzableTests {

    @Test("Custom struct generates fuzz values")
    func testCustomFuzzable() {
        let values = TestConfig.fuzz
        #expect(!values.isEmpty)
        print("TestConfig.fuzz generated \(values.count) values")
    }

    @Test("Custom struct mutations work")
    func testCustomMutation() {
        let original = TestConfig(timeout: 10, retries: 3)
        let mutations = original.mutate()

        #expect(!mutations.isEmpty)
        #expect(mutations.allSatisfy { $0 != original })
    }

    @Test("FuzzEngine works with custom types")
    func testFuzzEngineWithCustomType() {
        let config = FuzzEngine<TestConfig>.Config(
            maxIterations: 30,
            maxDuration: 5,
            verbose: false
        )

        let engine = FuzzEngine<TestConfig>(config: config, corpusDirectory: nil)

        var seenTimeouts: Set<Int> = []
        var seenRetries: Set<Int> = []

        let result = engine.run { input in
            seenTimeouts.insert(input.timeout)
            seenRetries.insert(input.retries)
        }

        #expect(!seenTimeouts.isEmpty)
        #expect(!seenRetries.isEmpty)
        #expect(result.failures.isEmpty)

        print("Saw \(seenTimeouts.count) unique timeouts, \(seenRetries.count) unique retries")
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
