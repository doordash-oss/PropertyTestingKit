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

//  Env-gated lock-acquisition metrics (PTK_LOCK_METRICS). A measurement scaffold
//  to validate empirically which locks (SyncBox, ComparisonDictionary) sit on the
//  per-dispatch hot path and whether they ever contend — before deciding which to
//  make lock-free. OFF by default: a disabled lock takes the plain acquire path
//  and pays nothing. When on, each acquisition bumps a per-label atomic counter,
//  and acquisitions that found the lock already held bump a separate "contended"
//  counter (via a non-blocking try first). Counters dump to stderr at exit.

import Foundation
import Atomics

/// Per-label aggregate acquisition counters. One instance per distinct label,
/// shared across every lock created with that label.
final class LockMetrics: @unchecked Sendable {
    let label: String
    let acquisitions = ManagedAtomic<Int>(0)
    let contended = ManagedAtomic<Int>(0)

    private init(label: String) { self.label = label }

    /// Process-wide enable, read from the environment. Not cached so tests can
    /// opt in per-instance via `forceMetrics` without depending on launch env.
    static var envEnabled: Bool {
        guard let v = ProcessInfo.processInfo.environment["PTK_LOCK_METRICS"] else { return false }
        return !v.isEmpty && v != "0"
    }

    /// Mutable registry state behind a single immutable `static let` so there is
    /// no nonisolated mutable global. All access is guarded by `lock`.
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var registry: [String: LockMetrics] = [:]
        var atexitInstalled = false
    }
    private static let store = Store()

    /// Return the shared counter for `label`, creating it once. Returns nil when
    /// metrics are disabled (and not force-enabled) — the caller then takes the
    /// plain, uninstrumented lock path.
    static func register(_ label: String, force: Bool = false) -> LockMetrics? {
        guard force || envEnabled else { return nil }
        store.lock.lock()
        defer { store.lock.unlock() }
        if !store.atexitInstalled {
            store.atexitInstalled = true
            atexit { LockMetrics.dump() }   // non-capturing → @convention(c)
        }
        if let m = store.registry[label] { return m }
        let m = LockMetrics(label: label)
        store.registry[label] = m
        return m
    }

    /// Test accessor: aggregate counts for a label, or nil if never registered.
    static func snapshotForTesting(_ label: String) -> (acquisitions: Int, contended: Int)? {
        store.lock.lock()
        defer { store.lock.unlock() }
        guard let m = store.registry[label] else { return nil }
        return (m.acquisitions.load(ordering: .relaxed), m.contended.load(ordering: .relaxed))
    }

    /// Write the per-label table to stderr, busiest first.
    static func dump() {
        store.lock.lock()
        let all = Array(store.registry.values)
        store.lock.unlock()
        guard !all.isEmpty else { return }
        let sorted = all.sorted {
            $0.acquisitions.load(ordering: .relaxed) > $1.acquisitions.load(ordering: .relaxed)
        }
        func pad(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }
        func lpad(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
        }
        var out = "=== PTK_LOCK_METRICS ===\n"
        out += pad("label", 40) + lpad("acquisitions", 16) + lpad("contended", 14) + "\n"
        for m in sorted {
            let a = m.acquisitions.load(ordering: .relaxed)
            let c = m.contended.load(ordering: .relaxed)
            out += pad(m.label, 40) + lpad("\(a)", 16) + lpad("\(c)", 14) + "\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
    }
}
