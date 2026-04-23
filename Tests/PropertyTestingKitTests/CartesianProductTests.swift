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

//  Tests for cartesianProduct function correctness.
//

import Testing
@testable import PropertyTestingKit

@Suite("CartesianProduct Tests")
struct CartesianProductTests {

    // MARK: - Empty Input Tests

    @Test("Empty single array returns empty result")
    func emptySingleArray() {
        let result = cartesianProduct([Int]())
        #expect(result.isEmpty)
    }

    @Test("Empty array in pair returns empty result")
    func emptyArrayInPair() {
        let result1 = cartesianProduct([Int](), ["a", "b"])
        #expect(result1.isEmpty)

        let result2 = cartesianProduct([1, 2], [String]())
        #expect(result2.isEmpty)
    }

    @Test("Empty array in triple returns empty result")
    func emptyArrayInTriple() {
        let result = cartesianProduct([1], [String](), [true])
        #expect(result.isEmpty)
    }

    // MARK: - Single Array Tests

    @Test("Single array with one element")
    func singleArrayOneElement() {
        let result = cartesianProduct([42])
        #expect(result.count == 1)
        #expect(result[0] == 42)
    }

    @Test("Single array with multiple elements")
    func singleArrayMultipleElements() {
        let result = cartesianProduct([1, 2, 3])
        #expect(result.count == 3)
        #expect(result[0] == 1)
        #expect(result[1] == 2)
        #expect(result[2] == 3)
    }

    // MARK: - Two Array Tests

    @Test("Two arrays - basic case")
    func twoArraysBasic() {
        let result = cartesianProduct([1, 2], ["a", "b"])

        #expect(result.count == 4)

        // Verify all combinations exist
        let tuples = result.map { ($0.0, $0.1) }
        #expect(tuples.contains { $0 == (1, "a") })
        #expect(tuples.contains { $0 == (1, "b") })
        #expect(tuples.contains { $0 == (2, "a") })
        #expect(tuples.contains { $0 == (2, "b") })
    }

    @Test("Two arrays - order is lexicographic")
    func twoArraysOrder() {
        let result = cartesianProduct([1, 2], ["a", "b"])

        // Expected order: (1,a), (1,b), (2,a), (2,b)
        #expect(result[0] == (1, "a"))
        #expect(result[1] == (1, "b"))
        #expect(result[2] == (2, "a"))
        #expect(result[3] == (2, "b"))
    }

    @Test("Two arrays - asymmetric sizes")
    func twoArraysAsymmetric() {
        let result = cartesianProduct([1, 2, 3], ["x"])

        #expect(result.count == 3)
        #expect(result[0] == (1, "x"))
        #expect(result[1] == (2, "x"))
        #expect(result[2] == (3, "x"))
    }

    // MARK: - Three Array Tests

    @Test("Three arrays - basic case")
    func threeArraysBasic() {
        let result = cartesianProduct([1, 2], ["a", "b"], [true, false])

        #expect(result.count == 8) // 2 * 2 * 2
    }

    @Test("Three arrays - correct count")
    func threeArraysCount() {
        let result = cartesianProduct([1, 2, 3], ["a", "b"], [true])

        #expect(result.count == 6) // 3 * 2 * 1
    }

    @Test("Three arrays - order is lexicographic")
    func threeArraysOrder() {
        let result = cartesianProduct([1, 2], ["a", "b"], [true, false])

        // First element of first array should vary slowest
        #expect(result[0] == (1, "a", true))
        #expect(result[1] == (1, "a", false))
        #expect(result[2] == (1, "b", true))
        #expect(result[3] == (1, "b", false))
        #expect(result[4] == (2, "a", true))
        #expect(result[5] == (2, "a", false))
        #expect(result[6] == (2, "b", true))
        #expect(result[7] == (2, "b", false))
    }

    // MARK: - Type Tests

    @Test("Mixed types in tuple")
    func mixedTypes() {
        let result = cartesianProduct([1], ["hello"], [3.14], [true])

        #expect(result.count == 1)
        let first = result[0]
        #expect(first.0 == 1)
        #expect(first.1 == "hello")
        #expect(first.2 == 3.14)
        #expect(first.3 == true)
    }

    @Test("Reference types")
    func referenceTypes() {
        class Box {
            let value: Int
            init(_ value: Int) { self.value = value }
        }

        let box1 = Box(1)
        let box2 = Box(2)

        let result = cartesianProduct([box1, box2], ["a"])

        #expect(result.count == 2)
        #expect(result[0].0 === box1)
        #expect(result[1].0 === box2)
    }

    // MARK: - Size Tests

    @Test("Large cartesian product has correct count")
    func largeProductCount() {
        let a = Array(1...10)
        let b = Array(1...10)
        let c = Array(1...10)

        let result = cartesianProduct(a, b, c)

        #expect(result.count == 1000) // 10 * 10 * 10
    }

    @Test("Single element arrays")
    func singleElementArrays() {
        let result = cartesianProduct([1], ["a"], [true])

        #expect(result.count == 1)
        #expect(result[0] == (1, "a", true))
    }

    // MARK: - Tuple Overload Tests

    @Test("Tuple input overload works")
    func tupleInputOverload() {
        let input = ([1, 2], ["a", "b"])
        let result = cartesianProduct(input)

        #expect(result.count == 4)
        #expect(result[0] == (1, "a"))
        #expect(result[3] == (2, "b"))
    }

    // MARK: - Edge Cases

    @Test("Duplicate elements preserved")
    func duplicateElements() {
        let result = cartesianProduct([1, 1], ["a"])

        #expect(result.count == 2)
        #expect(result[0] == (1, "a"))
        #expect(result[1] == (1, "a"))
    }

    @Test("Optional elements")
    func optionalElements() {
        let result = cartesianProduct([Optional(1), nil], ["a"])

        #expect(result.count == 2)
        #expect(result[0].0 == 1)
        #expect(result[1].0 == nil)
    }

    // Test added to check discovery
    @Test("New test for discovery check")
    func newDiscoveryCheck() {
        #expect(42 == 42)
    }
}
