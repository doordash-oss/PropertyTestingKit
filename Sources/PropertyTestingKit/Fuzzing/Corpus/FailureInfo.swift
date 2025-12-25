//
//  FailureInfo.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation
import Dependencies

/// Information about a failure caused by a corpus entry.
///
/// Based on Elhage 2020 "Property Testing Like AFL" - preserving failure-inducing
/// inputs is critical for regression testing and preventing bug recurrence.
public struct FailureInfo: Codable, Sendable {
    /// The type name of the error that occurred.
    public let errorType: String

    /// The localized error message.
    public let message: String

    /// Optional stack trace (if available).
    public let stackTrace: String?

    /// When this failure was first discovered.
    public let discoveredAt: Date

    public init(error: Error, stackTrace: String? = nil) {
        @Dependency(\.dateClient) var dateClient
        self.errorType = String(describing: type(of: error))
        self.message = error.localizedDescription
        self.stackTrace = stackTrace
        self.discoveredAt = dateClient.now()
    }

    public init(
        errorType: String,
        message: String,
        stackTrace: String? = nil,
        discoveredAt: Date? = nil
    ) {
        @Dependency(\.dateClient) var dateClient
        self.errorType = errorType
        self.message = message
        self.stackTrace = stackTrace
        if let discoveredAt = discoveredAt {
            self.discoveredAt = discoveredAt
        } else {
            self.discoveredAt = dateClient.now()
        }
    }
}
