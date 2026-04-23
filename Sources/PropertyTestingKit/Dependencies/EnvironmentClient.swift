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
//  EnvironmentClient.swift
//  PropertyTestingKit
//
//  Dependency client for environment variables to enable testing.
//

import Dependencies
import Foundation

/// Dependency client for accessing environment variables.
struct EnvironmentClient: Sendable {
    /// Get all environment variables.
    var environment: @Sendable () -> [String: String]

    init(environment: @escaping @Sendable () -> [String: String] = unimplemented(placeholder: [:])) {
        self.environment = environment
    }
}

extension EnvironmentClient {
    static let empty: EnvironmentClient = .init { [:] }
}

// MARK: - Dependency Key

extension EnvironmentClient: DependencyKey {
    static let liveValue = EnvironmentClient(
        environment: { ProcessInfo.processInfo.environment }
    )

    static let testValue = liveValue
}

extension DependencyValues {
    var environment: EnvironmentClient {
        get { self[EnvironmentClient.self] }
        set { self[EnvironmentClient.self] = newValue }
    }
}
