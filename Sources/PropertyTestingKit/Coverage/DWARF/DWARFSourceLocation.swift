//
//  DWARFSourceLocation.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// A source location resolved from DWARF debug information.
struct DWARFSourceLocation: Sendable, Equatable {
    /// The source file path.
    let file: String

    /// The line number (1-indexed).
    let line: Int

    /// The column number (1-indexed, 0 if unknown).
    let column: Int

    /// The function name (if available).
    let function: String?
}
