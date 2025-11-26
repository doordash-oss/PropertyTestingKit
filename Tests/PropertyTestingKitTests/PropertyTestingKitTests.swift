import Testing
@testable import PropertyTestingKit
import PropertyTestingKitMacros
import XCTest

func testVals(input: String, otherInput: Int) -> String {
    if otherInput > 30 {
        return "Mr. " + input + String(otherInput)
    }
    return input + String(otherInput)
}

struct Cat {
    let name: String
    let age: Int
}

extension Cat {
    static var fuzz: [Cat] {
        cartesianProduct(String.fuzz, Int.fuzz).map(Cat.init)
    }
}

// Example using the @Fuzzable macro
@Fuzzable
struct Dog {
    let age: Int
    let isBrown: Bool
}

// Nested fuzzable type - Human contains a Dog
@Fuzzable
struct Human {
    let age: Int
    let dog: Dog
}

@Test func fuzzableMacroGeneratesCorrectCombinations() {
    // Dog.fuzz should produce the cartesian product of Int.fuzz and Bool.fuzz
    let dogs = Dog.fuzz

    // Expected count: Int.fuzz.count * Bool.fuzz.count
    let expectedCount = Int.fuzz.count * Bool.fuzz.count
    #expect(dogs.count == expectedCount)

    // Verify that all combinations are present
    for intValue in Int.fuzz {
        for boolValue in Bool.fuzz {
            let matchingDog = dogs.contains { $0.age == intValue && $0.isBrown == boolValue }
            #expect(matchingDog, "Missing combination: age=\(intValue), isBrown=\(boolValue)")
        }
    }
}

@Test func fuzzableMacroProducesCorrectTypes() {
    // Verify that each element in Dog.fuzz is a Dog instance with proper values
    for dog in Dog.fuzz {
        #expect(Int.fuzz.contains(dog.age), "Dog age \(dog.age) should be in Int.fuzz")
        #expect(Bool.fuzz.contains(dog.isBrown), "Dog isBrown \(dog.isBrown) should be in Bool.fuzz")
    }
}

// MARK: - Nested Fuzzable Type Tests

@Test func nestedFuzzableGeneratesCorrectCount() {
    // Human.fuzz should produce the cartesian product of Int.fuzz and Dog.fuzz
    let humans = Human.fuzz

    // Expected count: Int.fuzz.count * Dog.fuzz.count
    // Dog.fuzz.count = Int.fuzz.count * Bool.fuzz.count
    let expectedDogCount = Int.fuzz.count * Bool.fuzz.count
    let expectedHumanCount = Int.fuzz.count * expectedDogCount
    #expect(humans.count == expectedHumanCount, "Expected \(expectedHumanCount) humans, got \(humans.count)")
}

@Test func nestedFuzzableContainsAllCombinations() {
    let humans = Human.fuzz

    // Verify all combinations of human age and dog are present
    for humanAge in Int.fuzz {
        for dog in Dog.fuzz {
            let matchingHuman = humans.contains {
                $0.age == humanAge && $0.dog.age == dog.age && $0.dog.isBrown == dog.isBrown
            }
            #expect(matchingHuman, "Missing combination: Human(age: \(humanAge), dog: Dog(age: \(dog.age), isBrown: \(dog.isBrown)))")
        }
    }
}

@Test func nestedFuzzableProducesValidValues() {
    // Verify each Human has valid values from the fuzz sources
    for human in Human.fuzz {
        #expect(Int.fuzz.contains(human.age), "Human age \(human.age) should be in Int.fuzz")
        #expect(Int.fuzz.contains(human.dog.age), "Dog age \(human.dog.age) should be in Int.fuzz")
        #expect(Bool.fuzz.contains(human.dog.isBrown), "Dog isBrown \(human.dog.isBrown) should be in Bool.fuzz")
    }
}

/*
 Properties
 Requirements
 Should cover inputs (both parameters and side effects)
 and outputs (both function returns and side effects).
 Should allow for concurrency.

*/
