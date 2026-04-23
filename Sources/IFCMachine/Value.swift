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
