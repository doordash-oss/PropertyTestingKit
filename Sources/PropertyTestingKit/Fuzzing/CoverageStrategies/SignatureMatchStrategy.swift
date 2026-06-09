// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//  Signature match strategy: exact edge-set matching via inverted index.
//

extension CoverageStrategy {
    /// Signature match strategy: exact edge-set matching via inverted index. Zero false positives.
    public static var signatureMatch: CoverageStrategy {
        CoverageStrategy(makeEngine: { makeSignatureMatchEngine() })
    }
}

/// Inverted index for exact edge-set duplicate detection.
///
/// Stores all previously-seen coverage signatures (edge sets) and provides
/// O(covered_edges) duplicate checking via an inverted index from edges to
/// signature IDs.
///
/// For each stored signature, tracks:
/// - Its total edge count
/// - A per-iteration hit counter (how many of its edges were seen this run)
///
/// The inverted index maps each edge index to the list of signature IDs that
/// contain it. When an edge is observed, its signatures' hit counters are
/// incremented. After all edges are observed, a signature is a match iff
/// `hits == signature_size AND covered_count == signature_size`.
private struct SignatureIndex {
    /// Number of edges in each stored signature.
    private var signatureSizes: [Int] = []

    /// Hit counters per signature, reset each iteration.
    private var signatureHits: [Int] = []

    /// Inverted index: edge index → list of signature IDs containing that edge.
    private var edgeToSignatures: [UInt32: [Int]] = [:]

    /// Number of stored signatures.
    var count: Int { signatureSizes.count }

    /// Reset all hit counters for a new iteration.
    mutating func resetHits() {
        for i in signatureHits.indices {
            signatureHits[i] = 0
        }
    }

    /// Check if the given covered edges exactly match any stored signature.
    ///
    /// - Parameter coveredIndices: Buffer of edge indices hit this run.
    /// - Returns: `true` if a matching signature exists (duplicate), `false` if novel.
    mutating func isDuplicate(coveredIndices: UnsafeBufferPointer<UInt32>) -> Bool {
        let coveredCount = coveredIndices.count
        if coveredCount == 0 { return false }

        // Reset hits from previous check
        resetHits()

        // Increment hit counters for each covered edge
        for i in 0..<coveredCount {
            let edge = coveredIndices[i]
            if let sigIDs = edgeToSignatures[edge] {
                for sigID in sigIDs {
                    signatureHits[sigID] += 1
                }
            }
        }

        // Check if any signature is fully matched
        for i in 0..<signatureSizes.count {
            if signatureHits[i] == signatureSizes[i] && coveredCount == signatureSizes[i] {
                return true
            }
        }
        return false
    }

    /// Register a new signature (edge set) in the index.
    ///
    /// - Parameter indices: The edge indices of the new signature.
    mutating func addSignature(_ indices: [UInt32]) {
        let sigID = signatureSizes.count
        signatureSizes.append(indices.count)
        signatureHits.append(0)

        for edge in indices {
            edgeToSignatures[edge, default: []].append(sigID)
        }
    }
}

/// Signature match strategy: exact edge-set matching via inverted index.
///
/// Zero false positives — if the edge set hasn't been seen before, it's
/// interesting. The inverted index is this engine's state, wrapped in a
/// `SyncBox` because the decision closure is `@Sendable`.
private func makeSignatureMatchEngine() -> CoverageEngine {
    let index = SyncBox(SignatureIndex())

    return CoverageEngine { sparse in
        let isDuplicate = index.update { idx in
            sparse.indices.withUnsafeBufferPointer { idx.isDuplicate(coveredIndices: $0) }
        }

        guard !isDuplicate else {
            return false
        }

        // Novel edge set — register it; the engine records the input.
        index.update { $0.addSignature(sparse.indices) }
        return true
    }
}
