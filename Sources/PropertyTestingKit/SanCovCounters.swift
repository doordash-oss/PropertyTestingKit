//
//  SanCovCounters.swift
//  PropertyTestingKit
//
//  Task-isolated coverage counters using SanitizerCoverage.
//
//  Unlike LLVM's global profile counters, these use task-keyed maps
//  that provide true per-task isolation even when tasks share threads.
//  This enables parallel fuzzing without coverage contamination.
//

import Foundation
import ValueProfileHooks

// MARK: - SparseCoverage

/// Efficient representation of sparse coverage data using parallel arrays.
///
/// This is significantly faster than `[Int: UInt8]` because it avoids
/// Dictionary hashing overhead. The indices and counts arrays are parallel:
/// `counts[i]` is the hit count for edge `indices[i]`.
public struct SparseCoverage: Sendable {
    /// Edge indices that were executed.
    public let indices: [UInt32]

    /// Hit counts for each edge (parallel to indices).
    public let counts: [UInt8]

    /// Number of covered edges.
    public var count: Int { indices.count }

    /// Whether any edges were covered.
    public var isEmpty: Bool { indices.isEmpty }

    /// Create from parallel arrays.
    public init(indices: [UInt32], counts: [UInt8]) {
        precondition(indices.count == counts.count, "indices and counts must have same length")
        self.indices = indices
        self.counts = counts
    }

    /// Create an empty sparse coverage.
    public init() {
        self.indices = []
        self.counts = []
    }
}

// MARK: - SanCovCounters

/// A snapshot of coverage counters with task-level isolation.
///
/// Unlike `CoverageCounters` which uses LLVM's global profile counters,
/// `SanCovCounters` uses SanitizerCoverage's trace_pc_guard callbacks with
/// task-keyed maps. This provides true per-task isolation even when
/// Swift Testing runs tasks on shared threads.
///
/// ## How It Works
///
/// When your code is compiled with `-sanitize-coverage=edge`, LLVM instruments
/// every edge (branch) with a callback to `__sanitizer_cov_trace_pc_guard`.
/// Our implementation keys coverage maps by `swift_task_getCurrent()`, so each
/// Swift async task gets its own isolated coverage map.
///
/// ## Usage
///
/// ```swift
/// // Reset coverage for this task
/// SanCovCounters.reset()
///
/// // Run code under test
/// myFunction()
///
/// // Get coverage for this task only
/// let snapshot = SanCovCounters.snapshot()
/// print("Covered \(snapshot?.coveredCount ?? 0) edges")
/// ```
///
/// ## Build Requirements
///
/// Your test target must be compiled with sanitizer coverage flags:
/// ```swift
/// .testTarget(
///     name: "MyTests",
///     swiftSettings: [
///         .unsafeFlags([
///             "-sanitize-coverage=edge,trace-cmp"
///         ])
///     ]
/// )
/// ```
public struct SanCovCounters: Sendable {
    /// The raw counter values (0 = not executed, 1 = executed).
    public let counters: [UInt8]

    /// Number of instrumented edges.
    public var count: Int { counters.count }

    /// Number of edges that were executed (non-zero counters).
    public var coveredCount: Int {
        counters.filter { $0 > 0 }.count
    }

    /// The set of edge indices that were executed.
    public var coveredIndices: Set<Int> {
        var indices = Set<Int>()
        for (index, value) in counters.enumerated() where value > 0 {
            indices.insert(index)
        }
        return indices
    }

    /// Create from raw counter array.
    public init(counters: [UInt8]) {
        self.counters = counters
    }

    /// Create from UInt64 counters (for test compatibility).
    /// Values are clamped to UInt8.max.
    public init(counters: [UInt64]) {
        self.counters = counters.map { UInt8(min($0, UInt64(UInt8.max))) }
    }

    // MARK: - Static API

    /// Check if SanitizerCoverage counters are available.
    ///
    /// Returns `true` if the binary was compiled with sanitizer coverage flags
    /// and the counters have been initialized.
    public static var isAvailable: Bool {
        sancov_counters_available()
    }

    /// Get the total number of instrumented edges.
    public static var totalEdgeCount: Int {
        sancov_get_counter_count()
    }

    /// Get the number of dladdr calls made (for profiling gap detection).
    public static var dlAddrCallCount: Int {
        Int(sancov_get_dladdr_call_count())
    }

    /// Reset the dladdr call counter.
    public static func resetDlAddrCallCount() {
        sancov_reset_dladdr_call_count()
    }

    /// Reset coverage counters for the current task.
    ///
    /// This only affects the current Swift task's coverage map.
    /// Other tasks running concurrently are not affected.
    ///
    /// - Note: In non-async contexts, falls back to thread-local storage.
    public static func reset() {
        sancov_reset_counters()
    }

    /// Get the number of edges covered by the current task.
    ///
    /// This only counts coverage from the current Swift task.
    /// Coverage from other concurrent tasks is not included.
    public static var currentCoveredCount: Int {
        sancov_get_covered_count()
    }

    /// Capture a snapshot of the current task's coverage.
    ///
    /// Returns `nil` if SanitizerCoverage is not available.
    ///
    /// - Note: The snapshot is isolated to the current Swift task.
    public static func snapshot() -> SanCovCounters? {
        guard isAvailable else { return nil }

        let count = sancov_get_counter_count()
        guard count > 0 else { return nil }

        // Allocate buffer and copy counters
        var buffer = [UInt8](repeating: 0, count: count)
        let copied = sancov_snapshot_counters(&buffer, count)
        guard copied == count else { return nil }

        return SanCovCounters(counters: buffer)
    }

    /// Get only the covered (non-zero) edge indices with their hit counts.
    /// This is more efficient than `snapshot()` when coverage is sparse.
    ///
    /// - Returns: Dictionary mapping edge index to hit count, or nil if unavailable.
    @available(*, deprecated, message: "Use snapshotCoveredArrays() for better performance")
    public static func snapshotCoveredOnly() -> [Int: UInt8]? {
        guard let sparse = snapshotCoveredArrays() else { return nil }
        var result: [Int: UInt8] = [:]
        result.reserveCapacity(sparse.count)
        for i in 0..<sparse.count {
            result[Int(sparse.indices[i])] = sparse.counts[i]
        }
        return result
    }

    /// Get only the covered (non-zero) edge indices with their hit counts.
    ///
    /// Returns parallel arrays for efficiency - avoids Dictionary hashing overhead.
    /// This is the fastest way to get sparse coverage data.
    ///
    /// - Returns: SparseCoverage with parallel indices/counts arrays, or nil if unavailable.
    public static func snapshotCoveredArrays() -> SparseCoverage? {
        guard isAvailable else { return nil }

        // Optimization: Use a single pass with a reasonable max buffer.
        // Coverage is typically sparse (<1% of edges hit), so 8K entries is usually enough.
        // If we need more, we fall back to the two-pass approach.
        let maxEntries = 8192

        // Single-pass: allocate buffer and fill in one call
        var indices = [UInt32](repeating: 0, count: maxEntries)
        var counts = [UInt8](repeating: 0, count: maxEntries)
        let filled = sancov_snapshot_covered_indices(&indices, &counts, maxEntries)

        // If buffer was too small, fall back to two-pass
        if filled == maxEntries {
            let actualCount = sancov_snapshot_covered_indices(nil, nil, 0)
            if actualCount > maxEntries {
                var largeIndices = [UInt32](repeating: 0, count: actualCount)
                var largeCounts = [UInt8](repeating: 0, count: actualCount)
                let actualFilled = sancov_snapshot_covered_indices(&largeIndices, &largeCounts, actualCount)

                // Trim to actual size
                largeIndices.removeLast(actualCount - actualFilled)
                largeCounts.removeLast(actualCount - actualFilled)
                return SparseCoverage(indices: largeIndices, counts: largeCounts)
            }
        }

        guard filled > 0 else { return SparseCoverage() }

        // Trim arrays to actual size
        indices.removeLast(maxEntries - filled)
        counts.removeLast(maxEntries - filled)
        return SparseCoverage(indices: indices, counts: counts)
    }

    // MARK: - Comparison

    /// Compute the difference between this snapshot and an earlier one.
    ///
    /// - Parameter earlier: The earlier snapshot to compare against.
    /// - Returns: A diff showing what changed between the two snapshots.
    public func difference(from earlier: SanCovCounters) -> SanCovDiff {
        let maxCount = max(counters.count, earlier.counters.count)

        var changed: [Int] = []
        var newlyCovered: [Int] = []

        for i in 0..<maxCount {
            let before = i < earlier.counters.count ? earlier.counters[i] : 0
            let after = i < counters.count ? counters[i] : 0

            if after != before {
                changed.append(i)
                if before == 0 && after > 0 {
                    newlyCovered.append(i)
                }
            }
        }

        return SanCovDiff(
            changedIndices: changed,
            newlyCoveredIndices: newlyCovered,
            before: earlier,
            after: self
        )
    }
}

// MARK: - SanCovDiff

/// The difference between two SanCovCounters snapshots.
public struct SanCovDiff: Sendable {
    /// Indices of counters that changed.
    public let changedIndices: [Int]

    /// Indices of counters that went from 0 to non-zero.
    public let newlyCoveredIndices: [Int]

    /// The earlier snapshot.
    public let before: SanCovCounters

    /// The later snapshot.
    public let after: SanCovCounters

    /// Number of edges that changed.
    public var changedCount: Int { changedIndices.count }

    /// Number of edges that were newly covered.
    public var newlyCoveredCount: Int { newlyCoveredIndices.count }

    /// Whether any coverage changed between the snapshots.
    public var hasChanges: Bool { !changedIndices.isEmpty }
}

// MARK: - Convenience API

/// Execute a closure and capture the coverage that changed (context-isolated).
///
/// This uses SanitizerCoverage with measurement contexts, providing true
/// per-call isolation. Multiple sync tests can run in parallel without
/// coverage contamination.
///
/// ```swift
/// let diff = measureSanCoverage {
///     myFunction()
/// }
/// print("Covered \(diff?.newlyCoveredCount ?? 0) new edges")
/// ```
///
/// - Parameter body: The code to measure.
/// - Returns: The coverage diff, or `nil` if SanCov unavailable.
@discardableResult
public func measureSanCoverage(_ body: () throws -> Void) rethrows -> SanCovDiff? {
    guard SanCovCounters.isAvailable else { return nil }
    guard let context = SanCovCounters.beginMeasurement() else { return nil }
    defer { SanCovCounters.endMeasurement(context) }

    let before = SanCovCounters.snapshot()
    try body()
    let after = SanCovCounters.snapshot()

    guard let before = before, let after = after else { return nil }
    return after.difference(from: before)
}

/// Execute an async closure and capture the coverage that changed (context-isolated).
///
/// - Note: Coverage remains isolated to the measurement context even across
///   suspension points where the task may hop threads.
@discardableResult
public func measureSanCoverage(_ body: () async throws -> Void) async rethrows -> SanCovDiff? {
    guard SanCovCounters.isAvailable else { return nil }
    guard let context = SanCovCounters.beginMeasurement() else { return nil }
    defer { SanCovCounters.endMeasurement(context) }

    let before = SanCovCounters.snapshot()
    try await body()
    let after = SanCovCounters.snapshot()

    guard let before = before, let after = after else { return nil }
    return after.difference(from: before)
}

// MARK: - Source Location Mapping

// Swift runtime demangling function
// char *swift_demangle(const char *mangledName, size_t mangledNameLength,
//                      char *outputBuffer, size_t *outputBufferSize, uint32_t flags);
@_silgen_name("swift_demangle")
private func swift_demangle(
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: Int,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<Int>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?

/// Demangle a Swift symbol name.
/// Returns the demangled name, or the original if demangling fails.
private func demangle(_ mangledName: String) -> String {
    guard let result = mangledName.withCString({ cString in
        swift_demangle(cString, mangledName.utf8.count, nil, nil, 0)
    }) else {
        return mangledName
    }
    defer { free(result) }
    return String(cString: result)
}

/// Source location information for a covered edge.
///
/// Maps a SanCov edge index to its source location using debug symbol info.
/// When DWARF debug info is available, provides line-level granularity.
/// Otherwise falls back to function-level info from dladdr.
public struct SanCovSourceLocation: Sendable {
    /// The source file path containing this edge.
    public let filename: String?

    /// The demangled function name containing this edge.
    public let functionName: String?

    /// The line number (1-indexed), or nil if unavailable.
    public let line: Int?

    /// The column number (1-indexed), or nil if unavailable.
    public let column: Int?

    /// The program counter (instruction address) for this edge.
    public let pc: UInt

    /// The function start address from dladdr (dli_saddr).
    /// This is the true beginning of the function, useful for computing function bounds.
    public let functionStart: UInt

    /// The SanCov edge index.
    public let edgeIndex: UInt32

    fileprivate init(from cLocation: SanCovSourceLocation_C, dwarfLocation: DWARFSourceLocation? = nil) {
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

// Type alias to avoid ambiguity with C struct
private typealias SanCovSourceLocation_C = ValueProfileHooks.SanCovSourceLocation

// MARK: - DWARF Symbolizer Integration

import MachO

/// Helper for DWARF-based line number resolution.
/// Lazily initializes the symbolizer on first use.
/// Actor-isolated to provide thread-safe access without locks.
private actor DWARFSymbolizerActor {
    private var _symbolizer: DWARFSymbolizer?
    private var _binaryPath: String?
    private var _slide: Int = 0
    private var _initialized = false

    /// Get or create the shared symbolizer for the current process.
    var shared: DWARFSymbolizer? {
        if !_initialized {
            _initialized = true
            initializeSymbolizer()
        }
        return _symbolizer
    }

    /// Get the ASLR slide for converting runtime addresses to file offsets.
    var slide: Int {
        if !_initialized {
            _initialized = true
            initializeSymbolizer()
        }
        return _slide
    }

    private func initializeSymbolizer() {
        // Find the main executable path
        guard let path = findMainBinaryPath() else {
            #if DEBUG
            print("[DWARFSymbolizer] Could not find main binary path")
            #endif
            return
        }
        _binaryPath = path

        // Find the slide for this binary
        _slide = findSlide(for: path)

        #if DEBUG
        print("[DWARFSymbolizer] Binary: \(path)")
        print("[DWARFSymbolizer] Slide: 0x\(String(_slide, radix: 16))")
        #endif

        // Create symbolizer
        do {
            _symbolizer = try DWARFSymbolizer(path: path)
            #if DEBUG
            print("[DWARFSymbolizer] Initialized successfully")
            #endif
        } catch {
            #if DEBUG
            print("[DWARFSymbolizer] Failed to initialize: \(error)")
            #endif
            // Symbolizer unavailable - that's okay, we fall back to dladdr
        }
    }

    private func findMainBinaryPath() -> String? {
        // Find the test binary by looking for .xctest bundle
        // The first image is often swiftpm-testing-helper, not the actual tests
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            let path = String(cString: name)

            // Look for .xctest bundle (Swift PM test binary)
            if path.contains(".xctest/") {
                return path
            }
        }

        // Fallback: first image
        guard _dyld_image_count() > 0,
              let name = _dyld_get_image_name(0) else {
            return nil
        }
        return String(cString: name)
    }

    private func findSlide(for path: String) -> Int {
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            if String(cString: name) == path {
                return _dyld_get_image_vmaddr_slide(i)
            }
        }
        return 0
    }

    /// Convert a runtime PC address to a file offset.
    /// Uses overflow-safe arithmetic since TSan can change memory layout
    /// in ways that make address calculations overflow.
    func runtimeToFileOffset(_ pc: UInt) -> UInt64 {
        let pcValue = UInt64(pc)
        let slideValue = UInt64(bitPattern: Int64(slide))
        // Use wrapping subtraction to avoid overflow trap
        return pcValue &- slideValue
    }

    /// Look up DWARF info for a PC address.
    func lookup(pc: UInt) async -> DWARFSourceLocation? {
        guard let symbolizer = shared else {
            return nil
        }
        let fileOffset = runtimeToFileOffset(pc)
        return await symbolizer.lookup(address: fileOffset)
    }

    /// Batch look up DWARF info for multiple PC addresses.
    /// Much faster than individual lookups due to reduced actor overhead.
    func lookupBatch(pcs: [UInt]) async -> [UInt: DWARFSourceLocation] {
        guard let symbolizer = shared else {
            return [:]
        }

        // Convert runtime PCs to file offsets
        let addresses = pcs.map { runtimeToFileOffset($0) }

        // Batch lookup
        let results = await symbolizer.lookup(addresses: addresses)

        // Map back to runtime PCs
        var pcResults: [UInt: DWARFSourceLocation] = [:]
        pcResults.reserveCapacity(results.count)
        for (i, pc) in pcs.enumerated() {
            let fileOffset = addresses[i]
            if let location = results[fileOffset] {
                pcResults[pc] = location
            }
        }
        return pcResults
    }

    /// Check if the symbolizer is available.
    var isAvailable: Bool {
        shared != nil
    }
}

/// Global actor instance for DWARF symbolization.
private let dwarfSymbolizerHelper = DWARFSymbolizerActor()

// MARK: - Function Size Lookup

/// Helper for looking up function sizes from the Mach-O symbol table.
/// Parses the symbol table once, then provides O(log n) lookups.
private actor FunctionSizeLookupActor {
    /// Sorted array of (address, size) for binary search
    private var _functionBounds: [(address: UInt, size: UInt)] = []
    private var _initialized = false
    private var _slide: Int = 0

    /// Initialize and parse the symbol table.
    private func initialize() {
        guard !_initialized else { return }
        _initialized = true

        // Find the test binary
        var targetImageIndex: UInt32 = 0
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            let path = String(cString: name)
            if path.contains(".xctest/") {
                targetImageIndex = i
                break
            }
        }

        guard let headerRaw = _dyld_get_image_header(targetImageIndex) else {
            return
        }
        _slide = _dyld_get_image_vmaddr_slide(targetImageIndex)

        // Cast to 64-bit header (we're always on 64-bit Apple Silicon)
        let header = UnsafeRawPointer(headerRaw).assumingMemoryBound(to: mach_header_64.self)

        // Parse symbol table from Mach-O header
        var symbols: [(address: UInt, name: String)] = []

        // Iterate load commands to find LC_SYMTAB
        var commandPtr = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = commandPtr.assumingMemoryBound(to: load_command.self).pointee

            if command.cmd == LC_SYMTAB {
                let symtabCmd = commandPtr.assumingMemoryBound(to: symtab_command.self).pointee

                // Get pointers to symbol table and string table
                let linkeditBase = findLinkeditBase(header: header)
                guard linkeditBase != nil else { break }

                let symtabPtr = linkeditBase!.advanced(by: Int(symtabCmd.symoff))
                    .assumingMemoryBound(to: nlist_64.self)
                let strtabPtr = linkeditBase!.advanced(by: Int(symtabCmd.stroff))
                    .assumingMemoryBound(to: CChar.self)

                // Extract function symbols (type 0x0f = N_SECT, external or local)
                for i in 0..<Int(symtabCmd.nsyms) {
                    let nlist = symtabPtr[i]
                    let type = nlist.n_type & UInt8(N_TYPE)

                    // Only include defined symbols in a section (functions/data)
                    if type == UInt8(N_SECT) {
                        let nameOffset = Int(nlist.n_un.n_strx)
                        let name = String(cString: strtabPtr.advanced(by: nameOffset))

                        // Filter to likely function symbols (not empty, not metadata)
                        if !name.isEmpty && !name.hasPrefix("_$s") == false {
                            let address = UInt(nlist.n_value) + UInt(bitPattern: _slide)
                            symbols.append((address: address, name: name))
                        }
                    }
                }
                break
            }

            commandPtr = commandPtr.advanced(by: Int(command.cmdsize))
        }

        // Sort by address
        symbols.sort { $0.address < $1.address }

        // Compute sizes as gaps between adjacent symbols
        _functionBounds.reserveCapacity(symbols.count)
        for i in 0..<symbols.count {
            let address = symbols[i].address
            let size: UInt
            if i + 1 < symbols.count {
                size = symbols[i + 1].address - address
            } else {
                size = 4096  // Default for last symbol
            }
            _functionBounds.append((address: address, size: size))
        }

        #if DEBUG
        print("[FunctionSizeLookup] Parsed \(_functionBounds.count) symbols from symbol table")
        #endif
    }

    /// Find the base address where linkedit segment is mapped.
    /// For a loaded binary, the linkedit data is at: slide + vmaddr
    private func findLinkeditBase(header: UnsafePointer<mach_header_64>) -> UnsafeRawPointer? {
        var commandPtr = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var linkeditVMAddr: UInt64 = 0
        var linkeditFileOff: UInt64 = 0
        var textVMAddr: UInt64 = 0

        for _ in 0..<header.pointee.ncmds {
            let command = commandPtr.assumingMemoryBound(to: load_command.self).pointee

            if command.cmd == LC_SEGMENT_64 {
                let segment = commandPtr.assumingMemoryBound(to: segment_command_64.self).pointee
                let segname = withUnsafeBytes(of: segment.segname) { ptr -> String in
                    let bytes = ptr.bindMemory(to: CChar.self)
                    return String(cString: bytes.baseAddress!)
                }
                if segname == "__LINKEDIT" {
                    linkeditVMAddr = segment.vmaddr
                    linkeditFileOff = segment.fileoff
                } else if segname == "__TEXT" {
                    textVMAddr = segment.vmaddr
                }
            }

            commandPtr = commandPtr.advanced(by: Int(command.cmdsize))
        }

        guard linkeditVMAddr > 0 else { return nil }

        // For a loaded binary with ASLR:
        // actual_linkedit_addr = slide + linkedit_vmaddr
        // The symtab/strtab offsets are relative to the start of linkedit data
        // So we need: slide + linkedit_vmaddr - linkedit_fileoff + offset
        // Which simplifies to: headerAddr - textVMAddr + linkedit_vmaddr - linkedit_fileoff + offset
        // Or: headerAddr + (linkedit_vmaddr - textVMAddr) - linkedit_fileoff + offset

        // Actually simpler: the linkedit base for offset lookups is:
        // slide + linkedit_vmaddr - linkedit_fileoff
        let slide = UInt64(bitPattern: Int64(_slide))
        let linkeditBase = slide + linkeditVMAddr - linkeditFileOff
        return UnsafeRawPointer(bitPattern: UInt(linkeditBase))
    }

    /// Look up the size of a function given its start address.
    /// Returns nil if the address is not found.
    func getSize(forFunctionAt address: UInt) -> UInt? {
        if !_initialized {
            initialize()
        }

        // Binary search for the address
        var low = 0
        var high = _functionBounds.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let entry = _functionBounds[mid]

            if entry.address == address {
                return entry.size
            } else if entry.address < address {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return nil
    }

    /// Get sizes for multiple function addresses at once.
    /// More efficient than individual lookups due to reduced actor overhead.
    func getSizes(forFunctionsAt addresses: [UInt]) -> [UInt: UInt] {
        if !_initialized {
            initialize()
        }

        var result: [UInt: UInt] = [:]
        result.reserveCapacity(addresses.count)

        for address in addresses {
            if let size = getSize(forFunctionAt: address) {
                result[address] = size
            }
        }

        return result
    }

    /// Check if the lookup table is available.
    var isAvailable: Bool {
        if !_initialized {
            initialize()
        }
        return !_functionBounds.isEmpty
    }
}

/// Global actor instance for function size lookup.
private let functionSizeLookup = FunctionSizeLookupActor()

extension SanCovCounters {
    /// Get the size of a function given its start address.
    /// Uses the Mach-O symbol table for accurate sizes.
    public static func getFunctionSize(at address: UInt) async -> UInt? {
        await functionSizeLookup.getSize(forFunctionAt: address)
    }

    /// Get sizes for multiple function addresses at once.
    public static func getFunctionSizes(at addresses: [UInt]) async -> [UInt: UInt] {
        await functionSizeLookup.getSizes(forFunctionsAt: addresses)
    }
}

extension SanCovCounters {
    /// Check if PC-to-source mapping is available.
    public static var pcsAvailable: Bool {
        sancov_pcs_available()
    }

    // MARK: - Measurement Context API

    /// An opaque measurement context for synchronous coverage isolation.
    ///
    /// Measurement contexts provide per-call isolation for synchronous code.
    /// When a context is active, coverage is keyed by the context rather than
    /// the Swift task or thread, enabling parallel sync tests without contamination.
    ///
    /// - Important: Measurement contexts are task-bound. You must call
    ///   `endMeasurement(_:)` from the same task that called `beginMeasurement()`.
    ///   The context is intentionally non-Sendable to enforce this requirement.
    public struct MeasurementContext {
        fileprivate let rawContext: UnsafeMutableRawPointer

        fileprivate init(_ raw: UnsafeMutableRawPointer) {
            self.rawContext = raw
        }
    }

    /// Begin a measurement context for synchronous coverage isolation.
    ///
    /// Coverage recorded while a context is active will be isolated to that context.
    /// The context takes priority over Swift task and thread-local coverage maps.
    ///
    /// - Important: You must call `endMeasurement(_:)` when done.
    /// - Returns: A context that must be passed to `endMeasurement(_:)`.
    public static func beginMeasurement() -> MeasurementContext? {
        guard let raw = sancov_begin_measurement() else { return nil }
        return MeasurementContext(raw)
    }

    /// End a measurement context and clean up its resources.
    ///
    /// - Parameter context: The context returned by `beginMeasurement()`.
    public static func endMeasurement(_ context: MeasurementContext) {
        sancov_end_measurement(context.rawContext)
    }

    /// Get the program counter for a given edge index.
    ///
    /// - Parameter edgeIndex: The edge index to look up.
    /// - Returns: The PC value, or 0 if unavailable.
    public static func getPC(for edgeIndex: Int) -> UInt {
        UInt(sancov_get_pc(edgeIndex))
    }

    /// Get source location info for a given edge index.
    ///
    /// When DWARF debug info is available, includes line and column numbers.
    /// Otherwise falls back to function-level info from dladdr.
    ///
    /// - Parameters:
    ///   - edgeIndex: The edge index to look up.
    ///   - includeDWARF: Whether to include DWARF debug info (slower but has line numbers).
    /// - Returns: Source location info, or nil if unavailable.
    public static func getSourceLocation(for edgeIndex: Int, includeDWARF: Bool = true) async -> SanCovSourceLocation? {
        var cLocation = SanCovSourceLocation_C()
        guard sancov_get_source_location(edgeIndex, &cLocation) else {
            return nil
        }

        // Try to get DWARF line info (expensive - skip if not needed)
        let dwarfLocation = includeDWARF ? await dwarfSymbolizerHelper.lookup(pc: UInt(cLocation.pc)) : nil
        return SanCovSourceLocation(from: cLocation, dwarfLocation: dwarfLocation)
    }

    /// Get source location info synchronously (no DWARF).
    ///
    /// This is faster than the async version when you don't need line numbers.
    /// Uses dladdr for function-level info only.
    ///
    /// - Parameter edgeIndex: The edge index to look up.
    /// - Returns: Source location info, or nil if unavailable.
    public static func getSourceLocationSync(for edgeIndex: Int) -> SanCovSourceLocation? {
        var cLocation = SanCovSourceLocation_C()
        guard sancov_get_source_location(edgeIndex, &cLocation) else {
            return nil
        }
        return SanCovSourceLocation(from: cLocation, dwarfLocation: nil)
    }

    /// Batch look up DWARF source locations for multiple PC addresses.
    ///
    /// Much faster than individual `getSourceLocation` calls when you need line numbers
    /// for many addresses, as it reduces actor overhead and batches LLVM lookups.
    ///
    /// - Parameter pcs: Array of program counter addresses to look up.
    /// - Returns: Dictionary mapping PCs to their DWARF source locations.
    public static func getDWARFLocations(for pcs: [UInt]) async -> [UInt: DWARFSourceLocation] {
        await dwarfSymbolizerHelper.lookupBatch(pcs: pcs)
    }

    /// Get source locations for all covered edges in the current task.
    ///
    /// This provides task-isolated coverage with source mapping.
    /// When DWARF debug info is available, each location includes line numbers.
    /// Otherwise falls back to function-level info.
    ///
    /// - Returns: Array of source locations for covered edges.
    public static func getCoveredLocations() async -> [SanCovSourceLocation] {
        // First, get the count
        let count = sancov_get_covered_locations(nil, 0)
        guard count > 0 else { return [] }

        // Allocate buffer and get locations
        var cLocations = [SanCovSourceLocation_C](repeating: SanCovSourceLocation_C(), count: count)
        let filled = sancov_get_covered_locations(&cLocations, count)

        // Convert to Swift types with DWARF line info when available
        var results: [SanCovSourceLocation] = []
        results.reserveCapacity(filled)
        for cLoc in cLocations.prefix(filled) {
            let dwarfLocation = await dwarfSymbolizerHelper.lookup(pc: UInt(cLoc.pc))
            results.append(SanCovSourceLocation(from: cLoc, dwarfLocation: dwarfLocation))
        }
        return results
    }

    /// Check if DWARF line-level symbolication is available.
    ///
    /// When `true`, `getSourceLocation` and `getCoveredLocations` will include
    /// line and column numbers. When `false`, only function-level info is available.
    public static func lineNumbersAvailable() async -> Bool {
        await dwarfSymbolizerHelper.isAvailable
    }
}

/// Coverage result with source-mapped locations (task-isolated).
///
/// When DWARF debug info is available, locations include line numbers,
/// enabling line-level coverage analysis.
public struct SanCovSourceCoverage: Sendable {
    /// All covered source locations.
    public let coveredLocations: [SanCovSourceLocation]

    /// Number of edges covered.
    public var coveredCount: Int { coveredLocations.count }

    /// Whether line numbers are available in the coverage data.
    public var hasLineNumbers: Bool {
        coveredLocations.contains { $0.line != nil }
    }

    /// Coverage grouped by file.
    public var byFile: [String: [SanCovSourceLocation]] {
        Dictionary(grouping: coveredLocations.filter { $0.filename != nil }) {
            $0.filename!
        }
    }

    /// Coverage grouped by function.
    public var byFunction: [String: [SanCovSourceLocation]] {
        Dictionary(grouping: coveredLocations.filter { $0.functionName != nil }) {
            $0.functionName!
        }
    }

    /// Coverage grouped by file and line (file:line -> locations).
    ///
    /// Only includes locations that have line numbers.
    public var byFileLine: [String: [SanCovSourceLocation]] {
        Dictionary(grouping: coveredLocations.filter { $0.filename != nil && $0.line != nil }) {
            "\($0.filename!):\($0.line!)"
        }
    }

    /// Get all unique files that were covered.
    public var coveredFiles: Set<String> {
        Set(coveredLocations.compactMap { $0.filename })
    }

    /// Get all unique functions that were covered.
    public var coveredFunctions: Set<String> {
        Set(coveredLocations.compactMap { $0.functionName })
    }

    /// Get all unique lines that were covered, grouped by file.
    ///
    /// Returns a dictionary mapping file paths to sets of covered line numbers.
    public var coveredLinesByFile: [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for loc in coveredLocations {
            guard let file = loc.filename, let line = loc.line else { continue }
            result[file, default: []].insert(line)
        }
        return result
    }

    /// Get a summary of covered lines per file.
    ///
    /// Returns formatted strings like "MyFile.swift: lines 10, 15, 20-25"
    public var lineCoverageSummary: [String] {
        coveredLinesByFile.map { (file, lines) in
            let sortedLines = lines.sorted()
            let ranges = collapseToRanges(sortedLines)
            let rangeStr = ranges.map { range in
                range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
            }.joined(separator: ", ")
            return "\(URL(fileURLWithPath: file).lastPathComponent): lines \(rangeStr)"
        }.sorted()
    }
}

/// Collapse consecutive integers into ranges.
private func collapseToRanges(_ sorted: [Int]) -> [ClosedRange<Int>] {
    guard !sorted.isEmpty else { return [] }

    var ranges: [ClosedRange<Int>] = []
    var start = sorted[0]
    var end = sorted[0]

    for i in 1..<sorted.count {
        if sorted[i] == end + 1 {
            end = sorted[i]
        } else {
            ranges.append(start...end)
            start = sorted[i]
            end = sorted[i]
        }
    }
    ranges.append(start...end)
    return ranges
}

/// Measure coverage with source location mapping (context-isolated).
///
/// This combines context-isolated SanCov coverage with source location mapping.
/// Coverage is isolated to a unique measurement context, allowing parallel test execution
/// without contamination - even for synchronous tests.
///
/// ```swift
/// let coverage = measureSanCovSourceCoverage {
///     myFunction()
/// }
/// for file in coverage?.coveredFiles ?? [] {
///     print("Covered: \(file)")
/// }
/// ```
///
/// - Parameter body: The code to measure.
/// - Returns: Source-mapped coverage, or nil if SanCov unavailable.
@discardableResult
public func measureSanCovSourceCoverage(_ body: () throws -> Void) async rethrows -> SanCovSourceCoverage? {
    guard SanCovCounters.isAvailable else { return nil }
    guard let context = SanCovCounters.beginMeasurement() else { return nil }
    defer { SanCovCounters.endMeasurement(context) }

    // Reset context-isolated counters
    SanCovCounters.reset()

    // Run the code
    try body()

    // Get source-mapped coverage
    let locations = await SanCovCounters.getCoveredLocations()
    return SanCovSourceCoverage(coveredLocations: locations)
}

/// Measure coverage with source location mapping (context-isolated, async body).
@discardableResult
public func measureSanCovSourceCoverage(_ body: () async throws -> Void) async rethrows -> SanCovSourceCoverage? {
    guard SanCovCounters.isAvailable else { return nil }
    guard let context = SanCovCounters.beginMeasurement() else { return nil }
    defer { SanCovCounters.endMeasurement(context) }

    // Reset context-isolated counters
    SanCovCounters.reset()

    // Run the code
    try await body()

    // Get source-mapped coverage
    let locations = await SanCovCounters.getCoveredLocations()
    return SanCovSourceCoverage(coveredLocations: locations)
}
