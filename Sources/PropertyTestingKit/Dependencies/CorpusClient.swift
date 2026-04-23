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

//  Dependency for creating corpus instances with generic type support.
//

import Dependencies
import Foundation

// MARK: - Corpus Registry

/// Registry for corpus instances.
///
/// Provides a factory for creating corpus instances with the appropriate type.
/// The Corpus type is ~Copyable (non-copyable) for performance optimization,
/// so it cannot be wrapped in closure-based clients.
struct CorpusRegistry: Sendable, CorpusRegistryProtocol {
    /// Create a corpus for the given input types.
    func getCorpus<each Input: Codable & Sendable>() -> Corpus<repeat each Input> {
        return Corpus<repeat each Input>()
    }
}

protocol CorpusRegistryProtocol: Sendable {
    func getCorpus<each T: Codable & Sendable>() -> Corpus<repeat each T>
}

// MARK: - Dependency Key

private struct CorpusRegistryKey: DependencyKey {
    static let liveValue: CorpusRegistryProtocol = CorpusRegistry()
    static let testValue: CorpusRegistryProtocol = liveValue
}

extension DependencyValues {
    /// Registry for corpus instances.
    ///
    /// Use this to create type-specific corpus instances:
    ///
    /// ```swift
    /// @Dependency(\.corpusRegistry) var registry
    /// var corpus: Corpus<Int> = registry.getCorpus()
    /// ```
    var corpusRegistry: CorpusRegistryProtocol {
        get { self[CorpusRegistryKey.self] }
        set { self[CorpusRegistryKey.self] = newValue }
    }
}
