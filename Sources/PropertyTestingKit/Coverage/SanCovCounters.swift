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
@_exported import EdgeHooks
import MachO

/// Namespace for SanitizerCoverage APIs with task-level isolation.
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
/// let context = SanCovCounters.beginMeasurement()
/// defer { SanCovCounters.endMeasurement(context) }
///
/// // Run code under test
/// myFunction()
///
/// // Get coverage for this context
/// let coverage = try SanCovCounters.snapshotCoveredArrays(with: context)
/// print("Covered \(coverage.indices.count) edges")
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
enum SanCovCounters {
    /// Check if SanitizerCoverage counters are available.
    ///
    /// Returns `true` if the binary was compiled with sanitizer coverage flags
    /// and the counters have been initialized.
    static var isAvailable: Bool {
        sancov_counters_available()
    }

    static func checkAvailabilty() throws {
        if !isAvailable {
            throw Errors.coverageNotAvailable
        }
    }

    enum Errors: Error {
        case coverageNotAvailable
    }

    /// Get the total number of instrumented edges.
    static var totalEdgeCount: Int {
        sancov_get_counter_count()
    }

    /// Get the number of edges covered by the current task.
    ///
    /// This only counts coverage from the current Swift task.
    /// Coverage from other concurrent tasks is not included.
    static var currentCoveredCount: Int {
        sancov_get_covered_count()
    }
}

// MARK: - Edge Hook

extension SanCovCounters {
    /// Install a custom edge hook that will be called on every edge hit.
    ///
    /// The hook receives the guard pointer — dereference it to get the edge index.
    /// Call `sancov_record_edge(guardPtr)` from your hook for default behavior.
    ///
    /// Pass `nil` to restore the default.
    ///
    /// - Important: Must be called before fuzzing starts. Not safe to call during fuzzing.
    public static func setEdgeHook(_ hook: EdgeHook?) {
        sancov_install_swift_hook(hook ?? defaultEdgeHook)
    }

    /// Attach a path trie to a measurement context.
    /// The trie edge hook reads the trie from the context on every edge hit.
    static func attachTrie(_ trie: PathTrie, to context: MeasurementContext) {
        trie.attach(to: context.rawContext)
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
func demangle(_ mangledName: String) -> String {
    guard let result = mangledName.withCString({ cString in
        swift_demangle(cString, mangledName.utf8.count, nil, nil, 0)
    }) else {
        return mangledName
    }
    defer { free(result) }
    return String(cString: result)
}

extension SanCovCounters {
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
    struct MeasurementContext {
        fileprivate let rawContext: UnsafeMutablePointer<SanCovMeasurementContext>

        fileprivate init(_ raw: UnsafeMutablePointer<SanCovMeasurementContext>) {
            self.rawContext = raw
        }

        /// Creates a dummy context for testing purposes.
        /// This context should only be used with mock CoverageCountersClients.
        static func testInstance() -> MeasurementContext {
            // Use C function to properly initialize all fields including atomic refcount
            guard let dummyPtr = sancov_create_dummy_context() else {
                fatalError("Failed to create dummy measurement context")
            }
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
    static func beginMeasurement() -> MeasurementContext {
        return MeasurementContext(sancov_begin_measurement())
    }

    /// End a measurement context and clean up its resources.
    ///
    /// - Parameter context: The context returned by `beginMeasurement()`.
    static func endMeasurement(_ context: MeasurementContext) {
        sancov_end_measurement(context.rawContext)
    }

    /// Reset coverage for a measurement context.
    ///
    /// This is a cheap operation (memset + counter reset) compared to
    /// end+begin which involves hash table insert/remove operations.
    /// Use this between iterations in the fuzz loop.
    ///
    /// - Parameter context: The measurement context to reset.
    static func resetCoverage(_ context: MeasurementContext) {
        sancov_reset_coverage(context.rawContext)
    }

    // MARK: - Context-Aware API
    // These methods operate directly on a measurement context, bypassing TLS lookup.
    // This is critical for Swift concurrency where tasks can hop between threads.

    /// Get the number of covered edges for a measurement context (O(1)).
    ///
    /// - Parameter context: The measurement context to query.
    /// - Returns: Number of covered edges.
    private static func getCoveredCount(with context: MeasurementContext) -> Int {
        sancov_get_covered_count_with_context(context.rawContext)
    }

    /// Get covered indices for a specific measurement context.
    ///
    /// This method uses the context directly, avoiding TLS lookup overhead.
    /// Much faster than `snapshotCoveredArrays()` when the context is known.
    ///
    /// - Parameter context: The measurement context to snapshot.
    /// - Returns: SparseCoverage with indices array, or nil if unavailable.
    static func snapshotCoveredArrays(with context: MeasurementContext) throws -> SparseCoverage {
        try checkAvailabilty()

        let count = getCoveredCount(with: context)
        guard count > 0 else { return SparseCoverage() }

        guard let ptr = sancov_snapshot_covered_indices_with_context(context.rawContext) else {
            return SparseCoverage()
        }
        defer { free(ptr) }

        let indices = Array(UnsafeBufferPointer(start: ptr, count: count))
        return SparseCoverage(indices: indices)
    }

    /// Get raw coverage data without creating a Swift array.
    ///
    /// This is useful when you want to check coverage uniqueness before allocating.
    /// The closure receives the raw pointer and count - do NOT store the pointer
    /// as it will be freed when the closure returns.
    ///
    /// - Parameters:
    ///   - context: The measurement context.
    ///   - body: Closure that receives the raw indices pointer and count.
    /// - Returns: The result of the closure.
    static func withRawCoverage<T>(
        context: MeasurementContext,
        body: @escaping (UnsafePointer<UInt32>?, Int) throws -> T
    ) throws -> T {
        try checkAvailabilty()

        let count = getCoveredCount(with: context)
        guard count > 0 else {
            return try body(nil, 0)
        }

        guard let ptr = sancov_snapshot_covered_indices_with_context(context.rawContext) else {
            return try body(nil, 0)
        }
        defer { free(ptr) }

        return try body(ptr, count)
    }

    /// Merge coverage from a measurement context directly into a bitmap.
    /// This is the fastest path - no allocation, early exit on first new coverage.
    ///
    /// - Parameters:
    ///   - context: The measurement context to read coverage from.
    ///   - bitmap: The bitmap storage to merge into.
    ///   - wordCount: Number of UInt64 words in the bitmap.
    ///   - mergeAll: If true, merge all edges; if false, return early on first new edge.
    /// - Returns: true if any new coverage was found, false otherwise.
    static func mergeCoverageIntoBitmap(
        context: MeasurementContext,
        bitmap: UnsafeMutablePointer<UInt64>,
        wordCount: Int,
        mergeAll: Bool
    ) -> Bool {
        guard isAvailable else { return false }
        return sancov_merge_coverage_into_bitmap(
            context.rawContext,
            bitmap,
            wordCount,
            mergeAll
        )
    }

    /// Compute signature hash from coverage data without allocation.
    /// This matches the SparseCoverage.signatureHash algorithm.
    ///
    /// - Parameter context: The measurement context.
    /// - Returns: The signature hash, or 0 if no coverage.
    static func computeSignatureHash(context: MeasurementContext) -> Int {
        guard isAvailable else { return 0 }
        return Int(sancov_compute_signature_hash(context.rawContext))
    }

    /// Compute signature hash from an explicit array of edge indices.
    /// Pure function — no dependency on live coverage counters.
    /// Uses the same algorithm as `computeSignatureHash(context:)`.
    static func computeSignatureHash(indices: [UInt32]) -> Int {
        indices.withUnsafeBufferPointer { buffer in
            Int(sancov_compute_hash_from_indices(buffer.baseAddress, buffer.count))
        }
    }

    /// Access the covered indices buffer directly (zero-copy).
    /// The pointer is valid until the next `resetCoverage` or `endMeasurement` call.
    ///
    /// - Returns: A buffer pointer to the covered indices, or nil if no coverage.
    static func withCoveredIndices<R>(
        context: MeasurementContext,
        body: (UnsafeBufferPointer<UInt32>) -> R
    ) -> R {
        var count: Int = 0
        let ptr = sancov_get_covered_indices(context.rawContext, &count)
        if let ptr, count > 0 {
            return body(UnsafeBufferPointer(start: ptr, count: count))
        }
        return body(UnsafeBufferPointer(start: nil, count: 0))
    }
}

// MARK: Coverage Gap Detection

/// Global instance for function size lookup (lazily initialized, thread-safe by Swift).
private let functionSizeLookup = FunctionSizeLookup()

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

extension SanCovCounters {
    /// Get the program counter for a given edge index.
    ///
    /// - Parameter edgeIndex: The edge index to look up.
    /// - Returns: The PC value, or 0 if unavailable.
    static func getPC(for edgeIndex: Int) -> UInt {
        UInt(sancov_get_pc(edgeIndex))
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

    /// Get sizes for multiple function addresses at once.
    static func getFunctionSizes(at addresses: [UInt]) -> [UInt: UInt] {
        functionSizeLookup.getSizes(forFunctionsAt: addresses)
    }
}

// Type alias to avoid ambiguity with C struct
typealias SanCovSourceLocation_C = SanCovHooks.SanCovSourceLocation

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

        preWarmTask = Task.detached(priority: .utility) { [self] in
            let total = SanCovCounters.totalEdgeCount
            guard total > 0 else { return }

            for edgeIndex in 0..<total {
                if Task.isCancelled { break }

                // Do the lookup which will cache as a side effect
                _ = await self.getOrLoad(edgeIndex)
            }

            await self.markPreWarmed()
        }
    }

    /// Mark the cache as fully pre-warmed.
    private func markPreWarmed() {
        isPreWarmed = true
    }
}
