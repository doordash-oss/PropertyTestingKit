//
//  Value.swift
//  IFCMachine
//
//  Values and labeled atoms for the IFC machine.
//

/// A machine value: integer, pointer, or label.
public enum Value: Sendable, Codable, Hashable {
    case int(Int)
    case ptr(block: Int, offset: Int)
    case label(Label)
}

/// An atom: a value paired with a security label.
/// Every piece of data in the machine carries its security classification.
public struct Atom: Sendable, Codable, Hashable {
    public var value: Value
    public var label: Label

    public init(_ value: Value, _ label: Label) {
        self.value = value
        self.label = label
    }

    /// Convenience for integer atoms.
    public static func int(_ n: Int, _ label: Label) -> Atom {
        Atom(.int(n), label)
    }
}
