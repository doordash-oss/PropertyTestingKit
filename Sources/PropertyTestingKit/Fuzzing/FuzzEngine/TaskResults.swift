//
//  TaskResults.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// A batch entry containing both input and metadata.
struct BatchEntry<each Input: Codable & Sendable>: Sendable {
    let input: (repeat each Input)
    let isMutation: Bool
}

/// Result type for parallel mutation testing.
struct BatchTestResult: Sendable {
    let index: Int
    let signature: CoverageSignature?
    let error: (any Error)?
    let timedOut: Bool
}

struct TestResult<each Input: Sendable>: Sendable {
    let input: (repeat each Input)
    let signature: CoverageSignature
    let status: TestResultStatus
}

enum TestResultStatus: Sendable {
    case error(any Error)
    case timeout
    case success
}
