//
//  DWARFSourceLocation.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// A source location resolved from DWARF debug information.
public struct DWARFSourceLocation: Sendable, Equatable {
    /// The source file path.
    public let file: String

    /// The line number (1-indexed).
    public let line: Int

    /// The column number (1-indexed, 0 if unknown).
    public let column: Int

    /// The function name (if available).
    public let function: String?
}
