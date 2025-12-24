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

/// Metadata for a batch entry (input stored separately due to generic constraints).
struct BatchEntryMeta: Sendable {
    let index: Int
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
