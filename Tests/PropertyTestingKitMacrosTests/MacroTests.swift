//
//  MacroTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import MacroTesting
import PropertyTestingKitMacros
import SwiftSyntaxMacros
import Testing

let macros: [String: any Macro.Type] = [
    "Fuzzable": FuzzableMacro.self
]

@Test func fuzzableMacroWithTwoProperties() {
    assertMacro(macros) {
        """
        @Fuzzable
        struct Cat {
            let age: Int
            let isBrown: Bool
        }
        """
    } expansion: {
        """
        struct Cat {
            let age: Int
            let isBrown: Bool

            static var fuzz: [Cat] {
                cartesianProduct(Int.fuzz, Bool.fuzz).map {
                    Cat.init(age: $0.0, isBrown: $0.1)
                }
            }
        }
        """
    }
}

@Test func fuzzableMacroWithSingleProperty() {
    assertMacro(macros) {
        """
        @Fuzzable
        struct SimpleType {
            let value: String
        }
        """
    } expansion: {
        """
        struct SimpleType {
            let value: String

            static var fuzz: [SimpleType] {
                cartesianProduct(String.fuzz).map {
                    SimpleType.init(value: $0.0)
                }
            }
        }
        """
    }
}

@Test func fuzzableMacroWithThreeProperties() {
    assertMacro(macros) {
        """
        @Fuzzable
        struct Person {
            let name: String
            let age: Int
            let isActive: Bool
        }
        """
    } expansion: {
        """
        struct Person {
            let name: String
            let age: Int
            let isActive: Bool

            static var fuzz: [Person] {
                cartesianProduct(String.fuzz, Int.fuzz, Bool.fuzz).map {
                    Person.init(name: $0.0, age: $0.1, isActive: $0.2)
                }
            }
        }
        """
    }
}

@Test func fuzzableMacroWithVarProperties() {
    assertMacro(macros) {
        """
        @Fuzzable
        struct MutableType {
            var count: Int
            var label: String
        }
        """
    } expansion: {
        """
        struct MutableType {
            var count: Int
            var label: String

            static var fuzz: [MutableType] {
                cartesianProduct(Int.fuzz, String.fuzz).map {
                    MutableType.init(count: $0.0, label: $0.1)
                }
            }
        }
        """
    }
}

@Test func fuzzableMacroIgnoresComputedProperties() {
    assertMacro(macros) {
        """
        @Fuzzable
        struct TypeWithComputed {
            let storedValue: Int
            var computed: String {
                return "computed"
            }
        }
        """
    } expansion: {
        """
        struct TypeWithComputed {
            let storedValue: Int
            var computed: String {
                return "computed"
            }

            static var fuzz: [TypeWithComputed] {
                cartesianProduct(Int.fuzz).map {
                    TypeWithComputed.init(storedValue: $0.0)
                }
            }
        }
        """
    }
}

@Test func fuzzableMacroWithNestedFuzzableType() {
    assertMacro(macros) {
        """
        @Fuzzable
        struct Dog {
            let age: Int
            let isBrown: Bool
        }

        @Fuzzable
        struct Human {
            let age: Int
            let dog: Dog
        }
        """
    } expansion: {
        """
        struct Dog {
            let age: Int
            let isBrown: Bool

            static var fuzz: [Dog] {
                cartesianProduct(Int.fuzz, Bool.fuzz).map {
                    Dog.init(age: $0.0, isBrown: $0.1)
                }
            }
        }
        struct Human {
            let age: Int
            let dog: Dog

            static var fuzz: [Human] {
                cartesianProduct(Int.fuzz, Dog.fuzz).map {
                    Human.init(age: $0.0, dog: $0.1)
                }
            }
        }
        """
    }
}

@Test func fuzzableMacroWithMultipleNestedTypes() {
    assertMacro(macros) {
        """
        @Fuzzable
        struct Dog {
            let age: Int
            let isBrown: Bool
        }

        @Fuzzable
        struct Human {
            let age: Int
            let dog: Dog
        }

        @Fuzzable
        struct Family {
            let parent: Human
            let child: Human
            let pet: Dog
        }
        """
    } expansion: {
        """
        struct Dog {
            let age: Int
            let isBrown: Bool

            static var fuzz: [Dog] {
                cartesianProduct(Int.fuzz, Bool.fuzz).map {
                    Dog.init(age: $0.0, isBrown: $0.1)
                }
            }
        }
        struct Human {
            let age: Int
            let dog: Dog

            static var fuzz: [Human] {
                cartesianProduct(Int.fuzz, Dog.fuzz).map {
                    Human.init(age: $0.0, dog: $0.1)
                }
            }
        }
        struct Family {
            let parent: Human
            let child: Human
            let pet: Dog

            static var fuzz: [Family] {
                cartesianProduct(Human.fuzz, Human.fuzz, Dog.fuzz).map {
                    Family.init(parent: $0.0, child: $0.1, pet: $0.2)
                }
            }
        }
        """
    }
}
