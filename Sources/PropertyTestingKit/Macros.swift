import Foundation

/// A macro that generates a parameterized test using fuzz values for each parameter type.
///
/// This macro transforms a function into a `@Test` with arguments generated from the
/// `.fuzz` property of each parameter type. It creates a cartesian product of all
/// fuzz values to test all combinations.
///
/// Example:
/// ```swift
/// @FuzzTest
/// func testExample(value: Int, text: String) {
///     // Test logic here
/// }
/// ```
///
/// Expands to:
/// ```swift
/// @Test("testExample", arguments: cartesianProduct(Int.fuzz, String.fuzz))
/// func testExample(value: Int, text: String) {
///     // Test logic here
/// }
/// ```
@attached(peer, names: named(fuzzy))
public macro FuzzTest() = #externalMacro(module: "PropertyTestingKitMacros", type: "FuzzTestMacro")

/// A macro that generates a `fuzz` static property for a type.
///
/// This macro creates a static `fuzz` property that returns an array of all
/// combinations of fuzz values for the type's stored properties using cartesian product.
///
/// Example:
/// ```swift
/// @Fuzzable
/// struct Cat {
///     let age: Int
///     let isBrown: Bool
/// }
/// ```
///
/// Expands to include:
/// ```swift
/// static var fuzz: [Cat] {
///     cartesianProduct(Int.fuzz, Bool.fuzz).map { Cat.init(age: $0.0, isBrown: $0.1) }
/// }
/// ```
///
/// If `Int.fuzz` produces `[1, 2]` and `Bool.fuzz` produces `[true, false]`,
/// then `Cat.fuzz` will produce:
/// `[Cat(age: 1, isBrown: true), Cat(age: 1, isBrown: false), Cat(age: 2, isBrown: true), Cat(age: 2, isBrown: false)]`
@attached(member, names: named(fuzz))
public macro Fuzzable() = #externalMacro(module: "PropertyTestingKitMacros", type: "FuzzableMacro")
