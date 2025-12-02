//
//  EnvironmentClient.swift
//  PropertyTestingKit
//
//  Dependency client for environment variables to enable testing.
//

import Dependencies
import Foundation

/// Dependency client for accessing environment variables.
public struct EnvironmentClient: Sendable {
    /// Get all environment variables.
    public var environment: @Sendable () -> [String: String]

    public init(environment: @escaping @Sendable () -> [String: String]) {
        self.environment = environment
    }
}

// MARK: - Dependency Key

extension EnvironmentClient: DependencyKey {
    public static let liveValue = EnvironmentClient(
        environment: { ProcessInfo.processInfo.environment }
    )

    public static let testValue = EnvironmentClient(
        environment: { [:] }
    )
}

extension DependencyValues {
    public var environment: EnvironmentClient {
        get { self[EnvironmentClient.self] }
        set { self[EnvironmentClient.self] = newValue }
    }
}
