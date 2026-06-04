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

// Regression test for the parallel-fuzz heap corruption root cause.
//
// A `SanCovPathTrie` and its owning `SanCovMeasurementContext` are linked by raw
// cross-pointers: `context->path_trie` and `trie->owner_context`. The two have
// independent lifetimes (the trie is owned by a Swift `PathTrie`; the context is
// C-refcounted). `sancov_trie_destroy` writes `owner_context->path_trie = NULL`,
// so if the context is freed first WITHOUT clearing the trie's back-pointer, the
// trie destroy writes through a dangling pointer — silently corrupting the heap
// free list under load (observed as torn String/Array buffers in unrelated code,
// e.g. swift-testing's Test.ID hashing, under 256-engine parallel fuzzing).

import Testing
import SanCovHooks

@Suite("Trie/owner-context lifetime", .serialized)
struct TrieOwnerContextLifetimeTests {

    /// Freeing the owning context must clear the trie's back-pointer, so a later
    /// `sancov_trie_destroy` does not write through a dangling `owner_context`.
    @Test("Freeing the owner context detaches the trie's back-pointer")
    func freeingContextDetachesTrie() {
        let ctx = sancov_create_dummy_context()
        let trie = sancov_trie_create()
        sancov_context_set_trie(ctx, trie)

        // Linked in both directions.
        #expect(sancov_trie_owner_context_for_testing(trie) == ctx)

        // Free the context while the trie still references it.
        sancov_release_for_testing(ctx)

        // The trie's back-pointer must no longer reference the freed context;
        // otherwise the destroy below writes `owner_context->path_trie = NULL`
        // into freed memory.
        #expect(sancov_trie_owner_context_for_testing(trie) == nil,
                "freeing the owner context must clear trie->owner_context")

        // Must be a safe no-op on the back-pointer (no write through a dangling ptr).
        sancov_trie_destroy(trie)
    }

    /// Symmetric direction: destroying the trie first must clear the context's
    /// forward pointer so the context never dereferences a freed trie.
    @Test("Destroying the trie clears the context's forward pointer")
    func destroyingTrieClearsContext() {
        let ctx = sancov_create_dummy_context()
        let trie = sancov_trie_create()
        sancov_context_set_trie(ctx, trie)

        sancov_trie_destroy(trie)

        #expect(ctx?.pointee.path_trie == nil,
                "destroying the trie must clear context->path_trie")

        sancov_release_for_testing(ctx)
    }
}
