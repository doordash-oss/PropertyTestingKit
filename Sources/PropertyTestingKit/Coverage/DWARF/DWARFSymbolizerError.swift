//
//  DWARFSymbolizerError.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// Errors that can occur during DWARF symbolication.
public enum DWARFSymbolizerError: Error, LocalizedError {
    case initFailed(String)
    case lookupFailed(String)
    case noDWARFInfo

    public var errorDescription: String? {
        switch self {
        case .initFailed(let msg): return "Failed to initialize DWARF reader: \(msg)"
        case .lookupFailed(let msg): return "DWARF lookup failed: \(msg)"
        case .noDWARFInfo: return "No DWARF debug information found"
        }
    }
}
