//
//  SanCovSourceLocation.swift
//  Copyright © 2026 DoorDash. All rights reserved.
//

/// Source location information for a covered edge.
///
/// Maps a SanCov edge index to its source location using debug symbol info.
/// When DWARF debug info is available, provides line-level granularity.
/// Otherwise falls back to function-level info from dladdr.
struct SanCovSourceLocation: Sendable {
    /// The source file path containing this edge.
    let filename: String?

    /// The demangled function name containing this edge.
    let functionName: String?

    /// The line number (1-indexed), or nil if unavailable.
    let line: Int?

    /// The column number (1-indexed), or nil if unavailable.
    let column: Int?

    /// The program counter (instruction address) for this edge.
    let pc: UInt

    /// The function start address from dladdr (dli_saddr).
    /// This is the true beginning of the function, useful for computing function bounds.
    let functionStart: UInt

    /// The SanCov edge index.
    let edgeIndex: UInt32

    init(from cLocation: SanCovSourceLocation_C, dwarfLocation: DWARFSourceLocation? = nil) {
        // Prefer DWARF info when available
        if let dwarf = dwarfLocation {
            self.filename = dwarf.file
            self.functionName = dwarf.function.map { demangle($0) }
            ?? cLocation.function_name.map { demangle(String(cString: $0)) }
            self.line = dwarf.line > 0 ? dwarf.line : nil
            self.column = dwarf.column > 0 ? dwarf.column : nil
        } else {
            self.filename = cLocation.filename.map { String(cString: $0) }
            self.functionName = cLocation.function_name.map { mangledName in
                demangle(String(cString: mangledName))
            }
            self.line = nil
            self.column = nil
        }
        self.pc = UInt(cLocation.pc)
        self.functionStart = UInt(cLocation.function_start)
        self.edgeIndex = cLocation.edge_index
    }
}

/// Check if a function name is from the Swift standard library.
///
/// When a toolchain instruments specialized stdlib code (e.g., `Array.map`),
/// those edges should typically be excluded from coverage analysis since
/// they're not part of the user's code under test.
///
/// - Parameter functionName: The demangled function name to check.
/// - Returns: `true` if this appears to be a stdlib function.
func isStdlibFunction(_ functionName: String) -> Bool {
    // Swift stdlib functions
    functionName.hasPrefix("Swift.") ||
    functionName.hasPrefix("(extension in Swift)") ||
    // Default arguments for stdlib functions (e.g., "default argument 1 of Swift.print(...)")
    (functionName.hasPrefix("default argument") && functionName.contains(" of Swift.")) ||
    // Swift runtime internals
    functionName.hasPrefix("__swift_") ||
    functionName.hasPrefix("_swift_") ||
    // Compiler-generated helpers
    functionName.hasPrefix("outlined ") ||
    functionName.contains("protocol witness table") ||
    functionName.contains("protocol conformance descriptor") ||
    // Common specialized stdlib functions that appear in user code
    functionName.contains("_endMutation") ||
    functionName.contains("_finalizeUninitializedArray") ||
    functionName.contains("_makeMutableAndUnique") ||
    functionName.contains("_bridgeToObjectiveC")
}
