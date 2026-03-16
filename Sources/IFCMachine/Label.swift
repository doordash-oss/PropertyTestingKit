//
//  Label.swift
//  IFCMachine
//
//  Security labels for information flow control.
//  Two-point lattice: Low (public) and High (secret).
//

/// A two-point security lattice: Low (public) and High (secret).
public enum Label: Sendable, Codable, Hashable, CaseIterable {
    case low
    case high

    /// Join (least upper bound): High if either is High.
    public func join(_ other: Label) -> Label {
        switch (self, other) {
        case (.low, .low): return .low
        default: return .high
        }
    }

    /// Does self flow to other? Low flows everywhere, High only flows to High.
    public func flowsTo(_ other: Label) -> Bool {
        switch (self, other) {
        case (.high, .low): return false
        default: return true
        }
    }
}
