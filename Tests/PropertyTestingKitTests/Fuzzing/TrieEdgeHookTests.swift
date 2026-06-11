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

//  Tests for the trie-based path tracking.
//  Drives PathTrie.advance directly to test the trie data structure
//  without going through the coverage system (avoids framework edge pollution).
//

import Testing
import SanCovHooks
@testable import PropertyTestingKit

@Suite("Trie Edge Hook")
struct TrieEdgeHookTests {

    // MARK: - Basic Path Tracking

    @Test("First path is always unique")
    func firstPathUnique() {
        let trie = PathTrie()
        trie.advance(0)
        trie.advance(1)
        #expect(trie.isUniquePath)
    }

    @Test("Same path twice is not unique")
    func samePathNotUnique() {
        let trie = PathTrie()

        // First run: 0 → 1
        trie.advance(0)
        trie.advance(1)
        #expect(trie.isUniquePath)
        trie.markTerminal()
        trie.reset()

        // Second run: same path 0 → 1
        trie.advance(0)
        trie.advance(1)
        #expect(!trie.isUniquePath)
    }

    @Test("Different path is unique")
    func differentPathUnique() {
        let trie = PathTrie()

        // First run: 0 → 1
        trie.advance(0)
        trie.advance(1)
        trie.markTerminal()
        trie.reset()

        // Second run: 0 → 2 (different second edge)
        trie.advance(0)
        trie.advance(2)
        #expect(trie.isUniquePath)
    }

    @Test("Reversed path is unique")
    func reversedPathUnique() {
        let trie = PathTrie()

        // First run: 0 → 1
        trie.advance(0)
        trie.advance(1)
        trie.markTerminal()
        trie.reset()

        // Second run: 1 → 0
        trie.advance(1)
        trie.advance(0)
        #expect(trie.isUniquePath)
    }

    // MARK: - Length Sensitivity

    @Test("Prefix of existing path is unique")
    func prefixIsUnique() {
        let trie = PathTrie()

        // First run: 0 → 1 → 2
        trie.advance(0)
        trie.advance(1)
        trie.advance(2)
        trie.markTerminal()
        trie.reset()

        // Second run: 0 → 1 (prefix)
        trie.advance(0)
        trie.advance(1)
        #expect(trie.isUniquePath, "Prefix of existing path should be unique")
    }

    @Test("Extension of existing path is unique")
    func extensionIsUnique() {
        let trie = PathTrie()

        // First run: 0 → 1
        trie.advance(0)
        trie.advance(1)
        trie.markTerminal()
        trie.reset()

        // Second run: 0 → 1 → 2 (extension — novel because edge 2 added new node)
        trie.advance(0)
        trie.advance(1)
        trie.advance(2)
        #expect(trie.isUniquePath, "Extension of existing path should be unique")
    }

    // MARK: - Multiple Paths

    @Test("Many unique paths then duplicate")
    func manyPathsThenDuplicate() {
        let trie = PathTrie()

        // Store 5 different paths
        for i: UInt32 in 0..<5 {
            trie.advance(0)
            trie.advance(i + 1)
            #expect(trie.isUniquePath)
            trie.markTerminal()
            trie.reset()
        }

        // Replay path 0 → 3 (already stored)
        trie.advance(0)
        trie.advance(3)
        #expect(!trie.isUniquePath, "Previously stored path should not be unique")
    }

    // MARK: - Novel Flag

    @Test("Novel flag set on first unseen edge")
    func novelFlagOnNewEdge() {
        let trie = PathTrie()

        // First run: 0 → 1
        trie.advance(0)
        trie.advance(1)
        trie.markTerminal()
        trie.reset()

        // Second run: 0 → 1 is terminal, so NOT unique
        trie.advance(0)
        trie.advance(1)
        #expect(!trie.isUniquePath)
        trie.reset()

        // Third run: 0 → 1 → 5 — novel flag should be set
        trie.advance(0)
        trie.advance(1)
        trie.advance(5)
        #expect(trie.isUniquePath, "Path with new edge should be unique via novel flag")
    }

    // MARK: - Reset

    @Test("Reset clears state for next iteration")
    func resetClearsState() {
        let trie = PathTrie()

        trie.advance(0)
        trie.advance(1)
        trie.markTerminal()
        trie.reset()

        // After reset, a completely new path should be unique
        trie.advance(9)
        #expect(trie.isUniquePath)
    }

    // MARK: - Loop Immunity

    @Test("Same edges in same order produce same path regardless of repeats")
    func repeatsIgnored() {
        let trie = PathTrie()

        // First run: edges 0, 1 (each advanced once — trie only sees first hits)
        trie.advance(0)
        trie.advance(1)
        trie.markTerminal()
        trie.reset()

        // Second run: same edges, same order — should be duplicate
        trie.advance(0)
        trie.advance(1)
        #expect(!trie.isUniquePath, "Same edge sequence should be duplicate")
    }

    // MARK: - Compound judge-and-mark

    /// Check-then-mark as two lock acquisitions lets a straggler `advance`
    /// (an un-awaited child task's edge) move the cursor between them,
    /// putting the terminal mark on the wrong node. The compound form judges
    /// and marks in one critical section.
    @Test("markTerminalIfUnique accepts and marks a novel path")
    func markTerminalIfUniqueAcceptsNovel() {
        let trie = PathTrie()
        trie.advance(0)
        trie.advance(1)
        #expect(trie.markTerminalIfUnique(), "First sight of a path is unique")
    }

    @Test("markTerminalIfUnique rejects a replayed path")
    func markTerminalIfUniqueRejectsReplay() {
        let trie = PathTrie()
        trie.advance(0)
        trie.advance(1)
        _ = trie.markTerminalIfUnique()
        trie.reset()

        trie.advance(0)
        trie.advance(1)
        #expect(!trie.markTerminalIfUnique(), "An identical replay is not unique")
    }

    // MARK: - Integration with Coverage System

    @Test("Trie advances on first-hit via the dispatched trie observer")
    func trieAdvancesViaDispatch() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        // The PRODUCTION .pathTrie engine: the context co-owns the observer
        // (and so the trie) — no lifetime pinning needed even though
        // instrumented edges keep dispatching.
        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.pathTrie.makeEvaluator()
        evaluator.setup?(context)

        var g0: UInt32 = 0
        var g1: UInt32 = 1
        sancov_dispatch_edge(&g0)
        sancov_dispatch_edge(&g1)

        // The dispatched edges must have advanced the engine's trie: a first
        // sight of this path judges unique.
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()
        #expect(evaluator.evaluate(1, nil, context, coverageClient, corpus) != nil)

        // Also verify coverage map was written
        let map = context.rawContext.pointee.coverage_map
        #expect(map?[0] == 1)
        #expect(map?[1] == 1)
    }

    // MARK: - Empty Path

    @Test("Empty path is unique on first run")
    func emptyPathFirstRun() {
        let trie = PathTrie()
        #expect(trie.isUniquePath)
    }

    @Test("Empty path is not unique after marking terminal")
    func emptyPathAfterTerminal() {
        let trie = PathTrie()
        trie.markTerminal()
        trie.reset()
        #expect(!trie.isUniquePath)
    }
}
