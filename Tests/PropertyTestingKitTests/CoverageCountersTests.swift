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

import Testing
@testable import PropertyTestingKit

// MARK: - SanCov Coverage Tests (Task-Isolated)

@Suite("SanCov Coverage API")
struct SanCovCoverageTests {

    @Test("Measurement context provides isolated coverage")
    func testMeasurementContext() throws {
        guard SanCovCounters.isAvailable else {
            Issue.record("SanCov counters not available")
            return
        }

        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        // Do some work
        var sum = 0
        for i in 0..<100 { sum += i }
        _ = sum

        // Get coverage from this context
        let coverage = try SanCovCounters.snapshotCoveredArrays(with: context)
        #expect(coverage.count > 0, "Should get coverage from context")
    }
}
