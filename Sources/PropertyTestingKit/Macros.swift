import Foundation

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
