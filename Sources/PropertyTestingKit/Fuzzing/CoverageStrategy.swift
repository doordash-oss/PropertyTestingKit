//
//  CoverageStrategy.swift
//  PropertyTestingKit
//
//  Swappable coverage strategies that determine when a fuzz input is "interesting."
//

/// Determines how the fuzzer decides if an input is interesting (i.e., worth adding to the corpus).
///
/// Different strategies trade off between precision and performance:
/// - `.signatureHash`: Fast hash-based check — new code path = new hash. Default.
/// - `.newEdge`: Bitmap merge — any previously-unseen edge is interesting. Matches AFL/libFuzzer.
/// - `.alwaysInteresting`: Every input is added. Useful for testing without coverage.
public enum CoverageStrategyKind: Sendable {
    /// Signature hash strategy (default).
    ///
    /// Computes a hash of the set of covered edges. An input is interesting
    /// if its signature hash hasn't been seen before, indicating a different
    /// code path even if all individual edges were previously covered.
    case signatureHash

    /// New edge strategy (bitmap merge).
    ///
    /// Uses `mergeCoverageIntoBitmap` to check if any previously-unseen edge
    /// was hit. Aligns with the AFL/libFuzzer model where any new edge is interesting.
    case newEdge

    /// Always interesting (for testing).
    ///
    /// Every input is added to the corpus unconditionally. Useful for tests
    /// that need deterministic corpus growth without depending on coverage data.
    case alwaysInteresting
}

/// A closure that decides if an input is interesting and adds it to the corpus.
///
/// Returns `true` if the input was interesting and added.
typealias CoverageStrategyFn<each Input: Codable & Sendable> = (
    _ input: (repeat each Input),
    _ context: SanCovCounters.MeasurementContext,
    _ coverageClient: CoverageCountersClient,
    _ corpus: Corpus<repeat each Input>
) -> Bool

/// Creates a coverage strategy closure for the given kind.
///
/// The returned closure encapsulates all interestingness logic and corpus addition.
/// It captures any mutable state it needs (e.g., the signature hash set).
func makeCoverageStrategy<each Input: Codable & Sendable>(
    _ kind: CoverageStrategyKind
) -> CoverageStrategyFn<repeat each Input> {
    switch kind {
    case .signatureHash:
        return makeSignatureHashStrategy()
    case .newEdge:
        return makeNewEdgeStrategy()
    case .alwaysInteresting:
        return makeAlwaysInterestingStrategy()
    }
}

// MARK: - Strategy Implementations

/// Signature hash strategy: computes a hash of covered edges, adds if hash is new.
///
/// Captures a `Set<Int>` of seen hashes in the closure's state.
private func makeSignatureHashStrategy<each Input: Codable & Sendable>(
) -> CoverageStrategyFn<repeat each Input> {
    var signatureHashes = Set<Int>()

    return { input, context, coverageClient, corpus in
        // Fast path: compute signature hash in C without allocation
        let hash = coverageClient.computeSignatureHash(context)

        // Check if this is a new code path
        guard !signatureHashes.contains(hash) else {
            return false
        }

        // New code path found - snapshot coverage and add entry
        guard let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) else {
            print("[SIG-HASH] REJECT: snapshot failed for hash=\(hash)")
            return false
        }

        // Track signature hash and merge coverage
        signatureHashes.insert(hash)
        corpus.mergeCoverageAndAdd(input: input, sparse: sparse)
        return true
    }
}

/// New edge strategy: uses bitmap merge to detect any previously-unseen edge.
///
/// Aligns with AFL/libFuzzer model.
private func makeNewEdgeStrategy<each Input: Codable & Sendable>(
) -> CoverageStrategyFn<repeat each Input> {
    return { input, context, coverageClient, corpus in
        // Merge coverage directly into corpus bitmap - returns true if any new edge found
        let foundNewEdge = coverageClient.mergeCoverageIntoBitmap(
            context,
            corpus.bitmapStorage,
            corpus.bitmapWordCount,
            true // mergeAll: merge all edges, not just new ones
        )

        guard foundNewEdge else {
            return false
        }

        // New edge found - snapshot for the corpus entry
        guard let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) else {
            return false
        }

        corpus.addEntry(input: input, sparse: sparse)
        return true
    }
}

/// Always interesting strategy: every input is added unconditionally.
private func makeAlwaysInterestingStrategy<each Input: Codable & Sendable>(
) -> CoverageStrategyFn<repeat each Input> {
    return { input, context, coverageClient, corpus in
        if let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) {
            corpus.mergeCoverageAndAdd(input: input, sparse: sparse)
        } else {
            corpus.addEntry(input: input, sparse: SparseCoverage())
        }
        return true
    }
}
