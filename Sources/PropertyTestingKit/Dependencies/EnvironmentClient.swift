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
