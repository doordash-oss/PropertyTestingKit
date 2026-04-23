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

/// The result of testing a candidate during shrinking.
public enum ShrinkResult: Sendable {
    /// Test passed (no failure) - this candidate doesn't preserve the property.
    case pass

    /// Test failed as expected - this candidate preserves the failure.
    case fail

    /// Test behaved unexpectedly (timeout, different error, exception).
    case unresolved
}
