//
//  ValueProfileDebugTest.swift
//  Debug test to verify value profile captures comparisons correctly
//

import Testing
@testable import PropertyTestingKit

@Suite("Value Profile Debug")
struct ValueProfileDebugTest {

    @Test("Debug: Check what comparisons are captured for array size check")
    func debugArraySizeComparisons() async throws {
        // Simple function with size check - defined at file scope to ensure it's compiled with instrumentation
        func checkSize(_ values: [Int]) -> String {
            if values.count >= 100 {
                return "large"
            }
            return "small"
        }

        // Manually enable VP, run a test, and dump comparisons
        let tracker = ValueProfileTracker()
        tracker.enable()

        print("\n=== Test 1: array size 5 ===")
        tracker.reset()
        let arr1 = [1, 2, 3, 4, 5]
        let result1 = checkSize(arr1)
        print("Result: \(result1)")
        ValueProfileTracker.dumpComparisons()

        print("\n=== Test 2: array size 50 ===")
        tracker.reset()
        let arr2 = Array(repeating: 0, count: 50)
        let result2 = checkSize(arr2)
        print("Result: \(result2)")
        ValueProfileTracker.dumpComparisons()

        print("\n=== Test 3: array size 100 ===")
        tracker.reset()
        let arr3 = Array(repeating: 0, count: 100)
        let result3 = checkSize(arr3)
        print("Result: \(result3)")
        ValueProfileTracker.dumpComparisons()

        print("\n=== Test 4: array size 150 ===")
        tracker.reset()
        let arr4 = Array(repeating: 0, count: 150)
        let result4 = checkSize(arr4)
        print("Result: \(result4)")
        ValueProfileTracker.dumpComparisons()

        tracker.disable()
    }

    @Test("Debug: Simulate fuzzer VP improvement detection")
    func debugVPImprovementDetection() async throws {
        func checkSize(_ values: [Int]) -> String {
            if values.count >= 100 {
                return "large"
            }
            return "small"
        }

        let tracker = ValueProfileTracker()
        tracker.enable()

        // Simulate fuzzer: test increasing sizes and check for improvements
        let sizes = [3, 6, 12, 24, 48, 96, 192]
        for size in sizes {
            tracker.reset()
            let arr = Array(repeating: 0, count: size)
            _ = checkSize(arr)
            let improvements = await tracker.processComparisons()
            print("Size \(size): \(improvements.count) improvements")
            if !improvements.isEmpty {
                for imp in improvements {
                    print("  -> distance=\(imp.distance) (arg1=\(imp.arg1), arg2=\(imp.arg2))")
                }
            }
        }

        tracker.disable()
    }

    @Test("Debug: Test array mutations include doubling")
    func debugArrayMutations() async throws {
        let arr = [0, 1, -1]  // Size 3
        let mutations = arr.mutate()

        print("Original array size: \(arr.count)")
        print("Number of mutations: \(mutations.count)")

        var sizes: [Int: Int] = [:]  // size -> count
        for m in mutations {
            sizes[m.count, default: 0] += 1
        }

        let sortedSizes = sizes.keys.sorted()
        for size in sortedSizes {
            print("  Size \(size): \(sizes[size]!) mutations")
        }

        // Check if doubling exists
        let doubled = mutations.contains { $0.count == arr.count * 2 }
        print("Has doubled mutation (size 6): \(doubled)")
    }

    @Test("Debug: Count all comparisons in a fuzz iteration")
    func debugAllComparisons() async throws {
        func checkSize(_ values: [Int]) -> String {
            if values.count >= 100 {
                return "large"
            }
            return "small"
        }

        let tracker = ValueProfileTracker()
        tracker.enable()

        // Run a simple fuzz-like test and count ALL comparisons
        print("\n=== Testing with size 10 array ===")
        tracker.reset()
        let arr = Array(repeating: 42, count: 10)
        _ = checkSize(arr)
        ValueProfileTracker.dumpComparisons()

        // Now check improvements
        let improvements = await tracker.processComparisons()
        print("Improvements detected: \(improvements.count)")

        tracker.disable()
    }

    @Test("Debug: Run actual fuzzer with size check")
    func debugActualFuzzer() async throws {
        nonisolated(unsafe) var maxArraySize = 0
        nonisolated(unsafe) var hitLarge = false

        let result = try await fuzz(
            iterations: 100,  // Small number
            duration: 60
        ) { (values: [Int]) in
            maxArraySize = max(maxArraySize, values.count)
            // Use the HardToFuzzFunctions version which is in the same compilation unit
            let output = largeArrayWithNegative(values)
            if output != "too-small" {
                hitLarge = true
                print("HIT LARGE! Size: \(values.count)")
            }
        }

        print("\n=== Fuzzer Results ===")
        print("Max array size: \(maxArraySize)")
        print("Hit large: \(hitLarge)")
        print("Total inputs: \(result.stats.totalInputs)")
        print("New paths: \(result.stats.newPaths)")
    }
}
