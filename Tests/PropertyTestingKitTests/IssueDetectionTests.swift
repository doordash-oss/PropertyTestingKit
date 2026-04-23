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

// Tests for lightweight issue detection.
//

import Testing
@testable import PropertyTestingKit

@Suite("Lightweight Issue Detection")
struct LightweightIssueDetectionTests {

    // MARK: - hasIssues tests

    @Test("hasIssues returns false when no issues")
    func hasIssuesReturnsFalseWhenNoIssues() async throws {
        let result = try await hasIssues {
            // No issues - just succeed
            #expect(1 == 1)
        }
        #expect(result == false)
    }

    @Test("hasIssues returns true when expectation fails")
    func hasIssuesReturnsTrueWhenExpectationFails() async throws {
        let result = try await hasIssues {
            // This will record an issue but not throw
            withKnownIssue {
                #expect(1 == 2)
            }
        }
        #expect(result == true)
    }

    @Test("hasIssues does not throw on issue")
    func hasIssuesDoesNotThrowOnIssue() async throws {
        // Should not throw even though there's a known issue
        let result = try await hasIssues {
            withKnownIssue {
                #expect(false)
            }
        }
        #expect(result == true)
    }

    @Test("hasIssues rethrows errors from body")
    func hasIssuesRethrowsErrors() async throws {
        struct TestError: Error {}

        do {
            _ = try await hasIssues {
                throw TestError()
            }
            Issue.record("Expected error to be thrown")
        } catch is TestError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - captureIssue tests

    @Test("captureIssue does not throw when no issues")
    func captureIssueDoesNotThrowWhenNoIssues() async throws {
        // Should complete without throwing
        try await captureIssue {
            #expect(1 == 1)
        }
    }

    @Test("captureIssue throws IssueRecordedError on expectation failure")
    func captureIssueThrowsOnExpectationFailure() async throws {
        do {
            try await captureIssue {
                withKnownIssue {
                    #expect(1 == 2)
                }
            }
            Issue.record("Expected IssueRecordedError to be thrown")
        } catch is IssueRecordedError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("captureIssue rethrows errors from body")
    func captureIssueRethrowsErrors() async throws {
        struct TestError: Error {}

        do {
            try await captureIssue {
                throw TestError()
            }
            Issue.record("Expected TestError to be thrown")
        } catch is TestError {
            // Expected - thrown errors take priority over recorded issues
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("captureIssue prioritizes thrown error over recorded issue")
    func captureIssuePrioritizesThrownError() async throws {
        struct TestError: Error {}

        do {
            try await captureIssue {
                // Record an issue first
                withKnownIssue {
                    #expect(false)
                }
                // Then throw an error
                throw TestError()
            }
            Issue.record("Expected TestError to be thrown")
        } catch is TestError {
            // Expected - thrown error should win over IssueRecordedError
        } catch is IssueRecordedError {
            Issue.record("IssueRecordedError thrown instead of TestError - priority wrong")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
