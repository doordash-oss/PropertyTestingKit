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

//  Dependency key for clock operations with safe test defaults.
//

import Clocks
import Dependencies
import Foundation

/// Dependency key for clock operations.
///
/// Uses `ContinuousClock` as both live and test values so PropertyTestingKit
/// doesn't interfere with users' tests. The built-in `\.continuousClock` from
/// swift-dependencies uses `UnimplementedClock` as its test value, which would
/// cause failures when users run their fuzz tests.
///
/// PropertyTestingKit's own tests can override with `ImmediateClock()` when needed.
private enum ContinuousClockClientKey: DependencyKey {
    static let liveValue: any Clock<Duration> = ContinuousClock()

    /// Test value uses real clock so we don't interfere with users' tests.
    static let testValue: any Clock<Duration> = ContinuousClock()
}

extension DependencyValues {
    var continuousClockClient: any Clock<Duration> {
        get { self[ContinuousClockClientKey.self] }
        set { self[ContinuousClockClientKey.self] = newValue }
    }
}
