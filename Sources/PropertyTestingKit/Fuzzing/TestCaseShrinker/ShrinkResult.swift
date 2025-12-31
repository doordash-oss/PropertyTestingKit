//
//  ShrinkResult.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

/// The result of testing a candidate during shrinking.
public enum ShrinkResult: Sendable {
    /// Test passed (no failure) - this candidate doesn't preserve the property.
    case pass

    /// Test failed as expected - this candidate preserves the failure.
    case fail

    /// Test behaved unexpectedly (timeout, different error, exception).
    case unresolved
}
