//
//  FuzzGenerator.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftCompilerPlugin

/// A macro that generates a `fuzz` static property for a type.
/// The property returns the cartesian product of all stored properties' fuzz values.
public struct FuzzableMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Get the type name
        guard let typeName = declaration.asProtocol(NamedDeclSyntax.self)?.name.text else {
            throw FuzzableMacroError.notANamedType
        }

        // Extract stored properties from the declaration
        let storedProperties = declaration.memberBlock.members.compactMap { member -> (name: String, type: String)? in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  varDecl.bindingSpecifier.tokenKind == .keyword(.let) || varDecl.bindingSpecifier.tokenKind == .keyword(.var) else {
                return nil
            }

            // Only include stored properties (not computed)
            for binding in varDecl.bindings {
                // Skip computed properties (those with accessors that aren't just initializers)
                if let accessor = binding.accessorBlock {
                    // Check if it's a computed property vs. willSet/didSet
                    switch accessor.accessors {
                    case .getter:
                        return nil
                    case .accessors(let accessorList):
                        let hasGetOrSet = accessorList.contains { accessor in
                            accessor.accessorSpecifier.tokenKind == .keyword(.get) ||
                            accessor.accessorSpecifier.tokenKind == .keyword(.set)
                        }
                        if hasGetOrSet {
                            return nil
                        }
                    }
                }

                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      let typeAnnotation = binding.typeAnnotation?.type else {
                    continue
                }

                return (name: pattern.identifier.text, type: typeAnnotation.trimmedDescription)
            }

            return nil
        }

        guard !storedProperties.isEmpty else {
            throw FuzzableMacroError.noStoredProperties
        }

        // Build the cartesianProduct call arguments
        let fuzzCalls = storedProperties.map { "\($0.type).fuzz" }.joined(separator: ", ")

        // Build the init arguments mapping tuple elements to property names
        let initArgs = storedProperties.enumerated().map { index, prop in
            "\(prop.name): $0.\(index)"
        }.joined(separator: ", ")

        // Build the fuzz property
        let fuzzProperty: DeclSyntax = """
            static var fuzz: [\(raw: typeName)] {
                cartesianProduct(\(raw: fuzzCalls)).map { \(raw: typeName).init(\(raw: initArgs)) }
            }
            """

        return [fuzzProperty]
    }
}

enum FuzzableMacroError: Error, CustomStringConvertible {
    case notANamedType
    case noStoredProperties

    var description: String {
        switch self {
        case .notANamedType:
            return "@Fuzzable can only be applied to a named type (struct, class, enum, or actor)"
        case .noStoredProperties:
            return "@Fuzzable requires at least one stored property"
        }
    }
}

@main
struct PropertyTestingKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        FuzzableMacro.self
    ]
}
