//
//  UncoveredRegion.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

/// An uncovered region within a function.
public struct UncoveredRegion: Sendable, Equatable {
    /// The starting line number (1-indexed). May be 0 if not yet resolved.
    public let lineStart: Int

    /// The starting column number (1-indexed). May be 0 if not yet resolved.
    public let columnStart: Int

    /// The ending line number (1-indexed).
    public let lineEnd: Int

    /// The ending column number (1-indexed).
    public let columnEnd: Int

    /// The edge index in the SanCov PC table.
    public let edgeIndex: Int

    /// The program counter for this edge (for lazy line lookup).
    public let pc: UInt

    /// Whether this region represents a branch (vs a statement).
    public let isBranch: Bool

    /// The file path for this specific uncovered region (from DWARF).
    /// May differ from the function's filename if the region crosses files.
    public let filePath: String?

    public init(
        lineStart: Int,
        columnStart: Int,
        lineEnd: Int = 0,
        columnEnd: Int = 0,
        edgeIndex: Int,
        pc: UInt = 0,
        isBranch: Bool = false,
        filePath: String? = nil
    ) {
        self.lineStart = lineStart
        self.columnStart = columnStart
        self.lineEnd = lineEnd > 0 ? lineEnd : lineStart
        self.columnEnd = columnEnd > 0 ? columnEnd : columnStart
        self.edgeIndex = edgeIndex
        self.pc = pc
        self.isBranch = isBranch
        self.filePath = filePath
    }
}
