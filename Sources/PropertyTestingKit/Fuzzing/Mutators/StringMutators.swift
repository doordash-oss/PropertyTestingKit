//
//  StringMutators.swift
//  PropertyTestingKit
//
//  Built-in string mutation strategies for fuzz testing.
//

// MARK: - String Mutator Static Properties

extension AnyMutator where Value == String {
    public static let phoneNumbers = AnyMutator(PhoneNumberMutator())
    public static let emails = AnyMutator(EmailMutator())
    public static let urls = AnyMutator(URLMutator())
    public static let sql = AnyMutator(SQLInjectionMutator())
    public static let xss = AnyMutator(XSSMutator())
    public static let unicode = AnyMutator(UnicodeMutator())
    public static let whitespace = AnyMutator(WhitespaceMutator())
    public static let empty = AnyMutator(EmptyStringMutator())
    public static let boundaries = AnyMutator(StringBoundaryMutator())
}

extension String {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ mutators: AnyMutator<String>...) -> AnyMutator<String> {
        AnyMutator(ComposedMutator(mutators))
    }
}
