//
//  StringMutators.swift
//  PropertyTestingKit
//
//  Built-in string mutation strategies for fuzz testing.
//

// MARK: - String Mutator Static Properties

extension Mutator where Value == String {
    public static let phoneNumbers = phoneNumberMutator
    public static let emails = emailMutator
    public static let urls = urlMutator
    public static let sql = sqlInjectionMutator
    public static let xss = xssMutator
    public static let unicode = unicodeMutator
    public static let whitespace = whitespaceMutator
    public static let empty = emptyStringMutator
    public static let boundaries = stringBoundaryMutator
}

extension String {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ mutators: Mutator<String>...) -> Mutator<String> {
        Mutator.compose(mutators)
    }
}
