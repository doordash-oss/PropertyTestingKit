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

//  Security labels for information flow control.
//  Two-point lattice: Low (public) and High (secret).
//

/// A two-point security lattice: Low (public) and High (secret).
public enum Label: Sendable, Codable, Hashable, CaseIterable {
    case low
    case high

    /// Join (least upper bound): High if either is High.
    public func join(_ other: Label) -> Label {
        switch (self, other) {
        case (.low, .low): return .low
        default: return .high
        }
    }

    /// Does self flow to other? Low flows everywhere, High only flows to High.
    public func flowsTo(_ other: Label) -> Bool {
        switch (self, other) {
        case (.high, .low): return false
        default: return true
        }
    }
}
