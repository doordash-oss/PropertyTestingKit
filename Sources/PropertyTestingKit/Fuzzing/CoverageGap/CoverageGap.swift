//
//  CoverageGap.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

/// A coverage gap in a partially-covered function.
public struct CoverageGap: Sendable, Equatable {
    /// The function name containing the gap.
    public let functionName: String

    /// Source file path.
    public let filename: String

    /// Uncovered regions within this function.
    public let uncoveredRegions: [UncoveredRegion]

    /// Number of covered edges in this function.
    public let coveredEdgeCount: Int

    /// Total number of edges in this function.
    public let totalEdgeCount: Int

    /// Coverage percentage for this function.
    public var coveragePercentage: Double {
        totalEdgeCount > 0 ? Double(coveredEdgeCount) / Double(totalEdgeCount) * 100 : 0
    }

    /// Whether this gap is significant (more than one uncovered edge).
    public var isSignificant: Bool {
        uncoveredRegions.count > 1 || (totalEdgeCount > 2 && coveragePercentage < 90)
    }

    public init(
        functionName: String,
        filename: String,
        uncoveredRegions: [UncoveredRegion],
        coveredEdgeCount: Int,
        totalEdgeCount: Int
    ) {
        self.functionName = functionName
        self.filename = filename
        self.uncoveredRegions = uncoveredRegions
        self.coveredEdgeCount = coveredEdgeCount
        self.totalEdgeCount = totalEdgeCount
    }
}
