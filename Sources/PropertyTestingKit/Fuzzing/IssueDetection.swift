//
// IssueDetection.swift
// PropertyTestingKit
//
// Lightweight issue detection for high-performance fuzzing.
// Uses Issue.onRecordCallback to bypass Configuration/Event overhead.
//

@_spi(ForToolsIntegrationOnly) import Testing

/// Error thrown when an issue is recorded during test execution.
public struct IssueRecordedError: Error {
    /// The underlying error from the issue, if available.
    public let underlyingError: (any Error)?

    public init(underlyingError: (any Error)? = nil) {
        self.underlyingError = underlyingError
    }
}

/// Internal class for capturing issues across async boundaries.
private final class IssueCapture: @unchecked Sendable {
    private var _error: (any Error)?

    var error: (any Error)? {
        get { _error }
        set { _error = newValue }
    }

    init() {
        _error = nil
    }
}

/// Task-local storage for the current issue capture context.
/// This allows concurrent test executions to capture issues independently.
@TaskLocal private var currentCapture: IssueCapture?

/// One-time registration of the issue callback.
/// The callback is invoked synchronously when any issue is recorded,
/// before the Event posting machinery runs.
/// Returns true to suppress normal recording when we have an active capture.
private let callbackRegistered: Bool = {
    Issue.onRecordCallback = { issue in
        guard let capture = currentCapture else {
            // No active capture - let normal recording proceed
            return false
        }
        // Capture first issue only
        if capture.error == nil {
            capture.error = issue.error ?? IssueRecordedError()
        }
        // Suppress normal recording to prevent issues from propagating
        return true
    }
    return true
}()

/// Ensures the callback is registered. Called at the start of each detection function.
@inline(__always)
private func ensureCallbackRegistered() {
    _ = callbackRegistered
}

/// Runs the given body and returns whether any issues were detected.
/// Uses the lightweight Issue.onRecordCallback which bypasses Event/Configuration overhead.
///
/// - Parameter body: The test body to execute.
/// - Returns: `true` if any issues were recorded, `false` otherwise.
/// - Throws: Re-throws if the body throws an error.
public func hasIssues(
    in body: () async throws -> Void
) async throws -> Bool {
    ensureCallbackRegistered()

    let capture = IssueCapture()

    try await $currentCapture.withValue(capture) {
        try await body()
    }

    return capture.error != nil
}

/// Runs the given body, capturing any issues as errors.
/// If any `#expect` failures or other issues are recorded, throws an error.
/// Thrown errors from the body take priority over recorded issues.
///
/// Uses the lightweight Issue.onRecordCallback which bypasses Event/Configuration overhead.
///
/// - Parameter body: The test body to execute.
/// - Throws: The error thrown by the body, or `IssueRecordedError` if an issue was recorded.
public func captureIssue(
    in body: () async throws -> Void
) async throws {
    ensureCallbackRegistered()

    let capture = IssueCapture()
    var thrownError: (any Error)?

    await $currentCapture.withValue(capture) {
        do {
            try await body()
        } catch {
            thrownError = error
        }
    }

    // Thrown error takes priority over recorded issue
    if let error = thrownError {
        throw error
    }
    if let error = capture.error {
        throw error
    }
}
