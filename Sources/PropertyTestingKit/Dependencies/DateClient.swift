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

//  Dependency client for date generation.
//

import Dependencies
import Foundation

/// Dependency client for generating dates.
///
/// Provides `Date()` as both live and test values so it doesn't interfere
/// with users' tests. PropertyTestingKit's internal tests can override this
/// to control timing when needed.
///
/// Note: `now` is synchronous because `Date()` is thread-safe and doesn't
/// require actor isolation. This avoids unnecessary async overhead in hot paths.
struct DateClient: Sendable {
    /// Generate the current date.
    var now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }
}

// MARK: - Convenience Initializers

extension DateClient {
    /// Create a client that always returns a constant date.
    static func constant(_ date: Date) -> DateClient {
        DateClient(now: { date })
    }
}

// MARK: - Dependency Key

extension DateClient: DependencyKey {
    static let liveValue = DateClient(now: { Date() })

    /// Test value uses real dates so we don't interfere with users' tests.
    /// PropertyTestingKit's own tests can override with `.constant()` when needed.
    static let testValue = liveValue
}

extension DependencyValues {
    var dateClient: DateClient {
        get { self[DateClient.self] }
        set { self[DateClient.self] = newValue }
    }
}
