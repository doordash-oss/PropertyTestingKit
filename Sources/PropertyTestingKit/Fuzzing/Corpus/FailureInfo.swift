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

    public init(error: Error, stackTrace: String? = nil) {
        self.errorType = String(describing: type(of: error))
        self.message = error.localizedDescription
        self.stackTrace = stackTrace
    }

    public init(
        errorType: String,
        message: String,
        stackTrace: String? = nil
    ) {
        self.errorType = errorType
        self.message = message
        self.stackTrace = stackTrace
    }
}
