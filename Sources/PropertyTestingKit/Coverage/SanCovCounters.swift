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
import SanCovHooks
import MachO

/// Global instance for DWARF symbolization (lazy to avoid initialization race).
private nonisolated(unsafe) var _dwarfSymbolizerHelper: DWARFSymbolizerHelper?
private let symbolizerInitLock = NSLock()

private func getDWARFSymbolizerHelper() -> DWARFSymbolizerHelper {
    symbolizerInitLock.lock()
    defer { symbolizerInitLock.unlock() }
    if _dwarfSymbolizerHelper == nil {
        _dwarfSymbolizerHelper = DWARFSymbolizerHelper()
    }
    return _dwarfSymbolizerHelper!
}

/// Global actor instance for function size lookup (lazy to avoid initialization race).
private nonisolated(unsafe) var _functionSizeLookup: FunctionSizeLookupHelper?
private let functionSizeInitLock = NSLock()

private func getFunctionSizeLookup() -> FunctionSizeLookupHelper {
    functionSizeInitLock.lock()
    defer { functionSizeInitLock.unlock() }
    if _functionSizeLookup == nil {
        _functionSizeLookup = FunctionSizeLookupHelper()
    }
    return _functionSizeLookup!
}

/// A snapshot of coverage counters with task-level isolation.
///
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
/// // Begin isolated measurement
/// guard let context = SanCovCounters.beginMeasurement() else { return }
/// defer { SanCovCounters.endMeasurement(context) }
///
/// // Run code under test
/// myFunction()
///
/// // Get coverage for this context
/// let coverage = SanCovCounters.snapshotCoveredArrays(with: context)
/// print("Covered \(coverage?.indices.count ?? 0) edges")
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
///             "-sanitize-coverage=edge,pc-table"
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

    /// Get the number of edges covered by the current task.
    ///
    /// This only counts coverage from the current Swift task.
    /// Coverage from other concurrent tasks is not included.
    static var currentCoveredCount: Int {
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

    /// Whether this location is from the Swift standard library.
    ///
    /// Some toolchains instrument specialized stdlib code (e.g., `Array.map`).
    /// This property helps filter those edges from coverage analysis.
    public var isStdlib: Bool {
        guard let name = functionName else { return false }
        return isStdlibFunction(name)
    }

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
private typealias SanCovSourceLocation_C = SanCovHooks.SanCovSourceLocation

// MARK: - Source Location Cache

/// Actor-based cache for dladdr-based source locations.
/// Pre-warming this cache in the background hides the latency of dladdr calls
/// by running them in parallel with the main fuzzing loop.
private actor SourceLocationCache {
    static let shared = SourceLocationCache()

    private var cache: [Int: SanCovSourceLocation] = [:]
    private var preWarmTask: Task<Void, Never>?
    private var isPreWarmed = false

    /// Get a cached location, or nil if not cached.
    func get(_ edgeIndex: Int) -> SanCovSourceLocation? {
        cache[edgeIndex]
    }

    /// Cache a location for an edge index.
    func set(_ edgeIndex: Int, _ location: SanCovSourceLocation) {
        cache[edgeIndex] = location
    }

    /// Get a location, using cache if available, otherwise doing dladdr lookup.
    func getOrLoad(_ edgeIndex: Int) -> SanCovSourceLocation? {
        // Check cache first
        if let cached = cache[edgeIndex] {
            return cached
        }

        // Cache miss - do the expensive dladdr call
        var cLocation = SanCovSourceLocation_C()
        guard sancov_get_source_location(edgeIndex, &cLocation) else {
            return nil
        }
        let location = SanCovSourceLocation(from: cLocation, dwarfLocation: nil)

        // Cache for future lookups
        cache[edgeIndex] = location
        return location
    }

    /// Check if the cache has been fully pre-warmed.
    var isFullyWarmed: Bool {
        isPreWarmed
    }

    /// Start pre-warming the cache in the background.
    /// This runs dladdr for all edges asynchronously, so by the time
    /// gap detection needs the data, it's already cached.
    func startPreWarming() {
        guard preWarmTask == nil else { return }

        preWarmTask = Task.detached(priority: .utility) {
            let total = SanCovCounters.totalEdgeCount
            guard total > 0 else { return }

            for edgeIndex in 0..<total {
                if Task.isCancelled { break }

                // Do the lookup which will cache as a side effect
                _ = await SourceLocationCache.shared.getOrLoad(edgeIndex)
            }

            await SourceLocationCache.shared.markPreWarmed()
        }
    }

    /// Mark the cache as fully pre-warmed.
    private func markPreWarmed() {
        isPreWarmed = true
    }

    /// Wait for pre-warming to complete (with timeout).
    ///
    /// - Parameter timeout: Maximum time to wait for pre-warming.
    func awaitPreWarming(timeout: Duration = .milliseconds(100)) async {
        guard let task = preWarmTask else { return }

        // Race between task completion and timeout
        _ = await runWithTimeout(timeout: timeout) {
            await task.value
        }
    }
}

extension SanCovCounters {
    /// Get the size of a function given its start address.
    /// Uses the Mach-O symbol table for accurate sizes.
    public static func getFunctionSize(at address: UInt) async -> UInt? {
        await getFunctionSizeLookup().getSize(forFunctionAt: address)
    }

    /// Get sizes for multiple function addresses at once.
    public static func getFunctionSizes(at addresses: [UInt]) async -> [UInt: UInt] {
        await getFunctionSizeLookup().getSizes(forFunctionsAt: addresses)
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

        /// Creates a dummy context for testing purposes.
        /// This context should only be used with mock CoverageCountersClients.
        public static func testInstance() -> MeasurementContext {
            // Allocate a small buffer that will be "freed" by the mock endMeasurement
            let dummyPtr = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
            return MeasurementContext(dummyPtr)
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

    // MARK: - Context-Aware API
    // These methods operate directly on a measurement context, bypassing TLS lookup.
    // This is critical for Swift concurrency where tasks can hop between threads.

    /// Get covered indices for a specific measurement context.
    ///
    /// This method uses the context directly, avoiding TLS lookup overhead.
    /// Much faster than `snapshotCoveredArrays()` when the context is known.
    ///
    /// - Parameter context: The measurement context to snapshot.
    /// - Returns: SparseCoverage with parallel indices/counts arrays, or nil if unavailable.
    static func snapshotCoveredArrays(with context: MeasurementContext) -> SparseCoverage? {
        guard isAvailable else { return nil }

        let maxEntries = 8192

        // Allocate uninitialized buffers to avoid zeroing 40KB per call.
        // The C function fills only the entries it needs.
        let indicesPtr = UnsafeMutablePointer<UInt32>.allocate(capacity: maxEntries)
        let countsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: maxEntries)
        defer {
            indicesPtr.deallocate()
            countsPtr.deallocate()
        }

        let filled = sancov_snapshot_covered_indices_with_context(
            context.rawContext,
            indicesPtr,
            countsPtr,
            maxEntries
        )

        guard filled > 0 else { return SparseCoverage() }

        // If buffer was too small, fall back to two-pass with larger buffers
        if filled == maxEntries {
            let actualCount = sancov_snapshot_covered_indices_with_context(context.rawContext, nil, nil, 0)
            if actualCount > maxEntries {
                let largeIndicesPtr = UnsafeMutablePointer<UInt32>.allocate(capacity: actualCount)
                let largeCountsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: actualCount)
                defer {
                    largeIndicesPtr.deallocate()
                    largeCountsPtr.deallocate()
                }

                let actualFilled = sancov_snapshot_covered_indices_with_context(
                    context.rawContext,
                    largeIndicesPtr,
                    largeCountsPtr,
                    actualCount
                )

                // Copy to Swift arrays (only the filled portion)
                let largeIndices = Array(UnsafeBufferPointer(start: largeIndicesPtr, count: actualFilled))
                let largeCounts = Array(UnsafeBufferPointer(start: largeCountsPtr, count: actualFilled))
                return SparseCoverage(indices: largeIndices, counts: largeCounts)
            }
        }

        // Copy to Swift arrays (only the filled portion)
        let indices = Array(UnsafeBufferPointer(start: indicesPtr, count: filled))
        let counts = Array(UnsafeBufferPointer(start: countsPtr, count: filled))
        return SparseCoverage(indices: indices, counts: counts)
    }

    /// Get the program counter for a given edge index.
    ///
    /// - Parameter edgeIndex: The edge index to look up.
    /// - Returns: The PC value, or 0 if unavailable.
    static func getPC(for edgeIndex: Int) -> UInt {
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
    func getSourceLocation(for edgeIndex: Int, includeDWARF: Bool = true) async -> SanCovSourceLocation? {
        var cLocation = SanCovSourceLocation_C()
        guard sancov_get_source_location(edgeIndex, &cLocation) else {
            return nil
        }

        // Try to get DWARF line info (expensive - skip if not needed)
        let dwarfLocation = includeDWARF ? await getDWARFSymbolizerHelper().lookup(pc: UInt(cLocation.pc)) : nil
        return SanCovSourceLocation(from: cLocation, dwarfLocation: dwarfLocation)
    }

    /// Get source location info with caching (no DWARF).
    ///
    /// Uses a shared cache to avoid repeated dladdr calls. When pre-warming
    /// is active, most lookups will be cache hits.
    ///
    /// - Parameter edgeIndex: The edge index to look up.
    /// - Returns: Source location info, or nil if unavailable.
    static func getSourceLocation(for edgeIndex: Int) async -> SanCovSourceLocation? {
        await SourceLocationCache.shared.getOrLoad(edgeIndex)
    }

    /// Start pre-warming the source location cache in the background.
    ///
    /// Call this at the start of a fuzz run to pre-populate the dladdr cache
    /// asynchronously. By the time gap detection runs at the end, the cache
    /// will be fully populated, eliminating dladdr latency.
    ///
    /// This is safe to call multiple times - subsequent calls are no-ops.
    static func startPreWarmingSourceLocations() async {
        await SourceLocationCache.shared.startPreWarming()
    }

    /// Wait for source location pre-warming to complete.
    ///
    /// - Parameter timeout: Maximum time to wait (default 100ms).
    static func awaitSourceLocationPreWarming(
        timeout: Duration = .milliseconds(100)
    ) async {
        await SourceLocationCache.shared.awaitPreWarming(timeout: timeout)
    }

    /// Batch look up DWARF source locations for multiple PC addresses.
    ///
    /// Much faster than individual `getSourceLocation` calls when you need line numbers
    /// for many addresses, as it reduces actor overhead and batches LLVM lookups.
    ///
    /// - Parameter pcs: Array of program counter addresses to look up.
    /// - Returns: Dictionary mapping PCs to their DWARF source locations.
    static func getDWARFLocations(for pcs: [UInt]) async -> [UInt: DWARFSourceLocation] {
        await getDWARFSymbolizerHelper().lookupBatch(pcs: pcs)
    }

    /// Get source locations for all covered edges in the current task.
    ///
    /// This provides task-isolated coverage with source mapping.
    /// When DWARF debug info is available, each location includes line numbers.
    /// Otherwise falls back to function-level info.
    ///
    /// - Parameter includeStdlib: If `false` (default), filters out Swift stdlib functions.
    ///   Some toolchains instrument specialized stdlib code which pollutes coverage data.
    /// - Returns: Array of source locations for covered edges.
    static func getCoveredLocations(includeStdlib: Bool = false) async -> [SanCovSourceLocation] {
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
            let dwarfLocation = await getDWARFSymbolizerHelper().lookup(pc: UInt(cLoc.pc))
            let location = SanCovSourceLocation(from: cLoc, dwarfLocation: dwarfLocation)

            // Filter out stdlib if requested
            if !includeStdlib && location.isStdlib {
                continue
            }

            results.append(location)
        }
        return results
    }

    /// Check if DWARF line-level symbolication is available.
    ///
    /// When `true`, `getSourceLocation` and `getCoveredLocations` will include
    /// line and column numbers. When `false`, only function-level info is available.
    static func lineNumbersAvailable() async -> Bool {
        await getDWARFSymbolizerHelper().isAvailable
    }
}
