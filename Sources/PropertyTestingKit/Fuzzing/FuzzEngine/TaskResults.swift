//
//  TaskResults.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// Result type for parallel seed execution.
/// Defined at file scope because Swift doesn't allow nested types in generic functions.
struct SeedTaskResult: Sendable {
    let index: Int
    let signature: CoverageSignature?
    let error: (any Error)?
    let timedOut: Bool
    let timeout: TimeInterval
}

/// A batch entry containing both input and metadata.
struct BatchEntry<each Input: Codable & Sendable>: Sendable {
    let input: (repeat each Input)
    let parentIndex: Int?
    let isMutation: Bool
}

/// Result type for parallel mutation testing.
struct BatchTestResult: Sendable {
    let index: Int
    let signature: CoverageSignature?
    let error: (any Error)?
    let timedOut: Bool
}
