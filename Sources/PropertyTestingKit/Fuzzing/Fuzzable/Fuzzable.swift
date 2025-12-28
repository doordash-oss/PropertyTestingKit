//
//  Fuzzable.swift
//  PropertyTestingKit
//
//  Protocol for types that can be fuzzed with coverage guidance.
//

import Foundation

/// A type that can generate test values and mutations for fuzzing.
///
/// Conforming types provide:
/// - `fuzz`: An array of interesting boundary values
/// - `mutate(_:)`: Generate variations of an existing value
///
/// The combination enables coverage-guided fuzzing: start with boundary
/// values, then mutate interesting inputs to explore nearby code paths.
///
/// ## Basic Conformance
///
/// For simple types, provide boundary values:
///
/// ```swift
/// extension MyEnum: Fuzzable {
///     static var fuzz: [MyEnum] { [.case1, .case2, .case3] }
/// }
/// ```
///
/// ## Mutation
///
/// The default mutation for enums cycles through all cases.
/// For structs/classes, override `mutate` to tweak individual fields:
///
/// ```swift
/// extension Config: Fuzzable {
///     static var fuzz: [Config] { /* boundary configs */ }
///
///     func mutate() -> [Config] {
///         // Mutate each field independently
///         timeout.mutate().map { Config(timeout: $0, retries: retries) } +
///         retries.mutate().map { Config(timeout: timeout, retries: $0) }
///     }
/// }
/// ```
public protocol Fuzzable {
    /// Boundary values to start fuzzing with.
    ///
    /// These should be "interesting" values that are likely to trigger
    /// different code paths: empty values, maximum values, edge cases, etc.
    static var fuzz: [Self] { get }

    /// Generate mutations of this value.
    ///
    /// Mutations should be "close" to the original value - small changes
    /// that might trigger nearby code paths. For example:
    /// - Numbers: increment, decrement, negate, halve, double
    /// - Strings: append, truncate, change case
    /// - Structs: mutate one field at a time
    ///
    /// Returns an empty array if no mutations are possible.
    func mutate() -> [Self]
}

extension Fuzzable where Self: Equatable {
    /// Default mutation returns all fuzz values except the current one.
    ///
    /// This provides basic mutation for types where field-level mutation
    /// doesn't make sense (like enums).
    public func mutate() -> [Self] {
        Self.fuzz.filter { $0 != self }
    }
}
