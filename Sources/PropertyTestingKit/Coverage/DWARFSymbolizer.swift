//
//  DWARFSymbolizer.swift
//  PropertyTestingKit
//
//  Native DWARF symbolication using LLVM for address-to-line lookup.
//

import Foundation
import CLLVMSymbolizer

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

/// Symbolizer that uses LLVM to resolve addresses to source locations.
///
/// Usage:
/// ```swift
/// let symbolizer = try DWARFSymbolizer(path: "/path/to/binary")
/// if let location = symbolizer.lookup(address: 0x100003f40) {
///     print("\(location.file):\(location.line)")
/// }
/// ```
public final class DWARFSymbolizer: @unchecked Sendable {
    private let symbolizerRef: LLVMSymbolizerRef
    private let lock = NSLock()

    /// Initialize a symbolizer for the given binary path.
    ///
    /// Automatically searches for dSYM bundles when the binary doesn't contain
    /// embedded debug info (common with Xcode's `dwarf-with-dsym` builds).
    ///
    /// - Parameter path: Path to the binary or dSYM with DWARF debug info.
    /// - Throws: `DWARFSymbolizerError` if initialization fails.
    public init(path: String) throws {
        // Try paths in order: dSYM first (more likely to have full debug info), then binary
        let pathsToTry = Self.findDebugInfoPaths(for: path)

        var lastError: String = "unknown error"
        for tryPath in pathsToTry {
            if let ref = llvm_symbolizer_create(tryPath) {
                self.symbolizerRef = ref
                return
            }
            lastError = llvm_symbolizer_get_error().map { String(cString: $0) } ?? "unknown error"
        }

        throw DWARFSymbolizerError.initFailed(lastError)
    }

    /// Initialize a symbolizer for the current process executable.
    public convenience init() throws {
        let path = ProcessInfo.processInfo.arguments[0]
        try self.init(path: path)
    }

    /// Find possible paths containing debug info for a binary.
    ///
    /// Searches for dSYM bundles in common locations:
    /// - Adjacent to .xctest/.app/.framework bundle
    /// - Adjacent to standalone binary (non-bundle case)
    private static func findDebugInfoPaths(for binaryPath: String) -> [String] {
        var paths: [String] = []
        let fm = FileManager.default

        // Get binary name
        let binaryURL = URL(fileURLWithPath: binaryPath)
        let binaryName = binaryURL.lastPathComponent

        // Look for dSYM adjacent to bundle (.xctest, .app, etc.)
        // Binary: /path/to/Foo.xctest/Contents/MacOS/Foo
        // dSYM:   /path/to/Foo.xctest.dSYM/Contents/Resources/DWARF/Foo
        var foundBundle = false
        var searchURL = binaryURL.deletingLastPathComponent()
        while searchURL.path != "/" {
            let parentName = searchURL.lastPathComponent
            if parentName.hasSuffix(".xctest") || parentName.hasSuffix(".app") || parentName.hasSuffix(".framework") {
                foundBundle = true
                let dsymPath = searchURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(parentName).dSYM")
                    .appendingPathComponent("Contents/Resources/DWARF")
                    .appendingPathComponent(binaryName)
                    .path
                if fm.fileExists(atPath: dsymPath) {
                    paths.append(dsymPath)
                }
                break
            }
            searchURL = searchURL.deletingLastPathComponent()
        }

        // For standalone binaries (not in a bundle), check for dSYM adjacent to binary
        // Binary: /path/to/Foo
        // dSYM:   /path/to/Foo.dSYM/Contents/Resources/DWARF/Foo
        if !foundBundle {
            let adjacentDsym = binaryURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(binaryName).dSYM")
                .appendingPathComponent("Contents/Resources/DWARF")
                .appendingPathComponent(binaryName)
                .path
            if fm.fileExists(atPath: adjacentDsym) {
                paths.append(adjacentDsym)
            }
        }

        // Always try the original binary path last
        paths.append(binaryPath)

        return paths
    }

    deinit {
        llvm_symbolizer_destroy(symbolizerRef)
    }

    /// Look up source location for a given address.
    ///
    /// - Parameter address: The program counter address to look up.
    /// - Returns: The source location, or nil if not found.
    public func lookup(address: UInt64) -> DWARFSourceLocation? {
        lock.lock()
        defer { lock.unlock() }

        var result = llvm_symbolizer_lookup(symbolizerRef, address)
        defer { llvm_symbolizer_free_result(&result) }

        guard result.success else {
            return nil
        }

        let file = result.file.map { String(cString: $0) } ?? ""
        let function = result.function.map { String(cString: $0) }

        return DWARFSourceLocation(
            file: file,
            line: Int(result.line),
            column: Int(result.column),
            function: function
        )
    }

    /// Look up source locations for multiple addresses.
    ///
    /// - Parameter addresses: The addresses to look up.
    /// - Returns: Dictionary mapping addresses to their source locations.
    public func lookup(addresses: [UInt64]) -> [UInt64: DWARFSourceLocation] {
        lock.lock()
        defer { lock.unlock() }

        var results: [UInt64: DWARFSourceLocation] = [:]

        for addr in addresses {
            var result = llvm_symbolizer_lookup(symbolizerRef, addr)
            defer { llvm_symbolizer_free_result(&result) }

            if result.success {
                let file = result.file.map { String(cString: $0) } ?? ""
                let function = result.function.map { String(cString: $0) }

                results[addr] = DWARFSourceLocation(
                    file: file,
                    line: Int(result.line),
                    column: Int(result.column),
                    function: function
                )
            }
        }

        return results
    }

    /// Find the closest source location for an address.
    ///
    /// Unlike `lookup(address:)` which requires debug info at the exact address,
    /// this attempts to find info for the given address which may map to
    /// nearby source locations.
    ///
    /// - Parameter address: The address to find.
    /// - Returns: The source location, or nil if not found.
    public func findClosest(address: UInt64) -> DWARFSourceLocation? {
        // LLVM's symbolizer already handles finding the closest match
        return lookup(address: address)
    }
}

// MARK: - Convenience Extensions

extension DWARFSymbolizer {
    /// Symbolicate addresses from SanCov PC table entries.
    ///
    /// - Parameter pcAddresses: Array of PC addresses from sanitizer coverage.
    /// - Returns: Dictionary mapping addresses to source locations.
    public func symbolicateSanCovAddresses(_ pcAddresses: [UInt64]) -> [UInt64: DWARFSourceLocation] {
        lookup(addresses: pcAddresses)
    }
}
