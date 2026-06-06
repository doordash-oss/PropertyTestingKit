import Testing
import Foundation
import Dependencies
@testable import PropertyTestingKit

/// Guards against a swift-dependencies footgun: a `liveValue` is cached process-wide,
/// and `@Dependency` binds to the context where its wrapper is *initialized*. If a
/// `liveValue`'s closures capture a nested `@Dependency` at construction, then whichever
/// task first triggers that `liveValue` computation under the parallel test suite binds
/// *its* (possibly-overridden) dependency into the cached client for the whole process.
///
/// This is exactly what made `realisticCoverageGapTest` flaky (2026-06-06): a concurrent
/// test's `\.fileManager` mock (whose `fileExists` defaults to `false`) was captured by
/// the cached `corpusPersistence.liveValue`, so `regress`'s `exists()` returned false even
/// though the corpus file was present. The fix: resolve nested `@Dependency` *per call*.
///
/// KEY to reproducing: the `exists()` call must run with NO `\.fileManager` override active
/// — a call-time override takes precedence and masks a stale captured value. So we build the
/// client under a mock, then invoke it ambiently (live filesystem) against real temp files.
@Suite("Dependency liveValue isolation")
struct DependencyLiveValueIsolationTests {

    /// Built under a `fileExists → false` mock, then invoked ambiently against a directory
    /// that really contains `corpus.json`. Per-call resolution (the fix) consults the live
    /// filesystem → `true`. The pre-fix code reuses the captured `false` mock → `false`.
    @Test("live corpus client does not capture a stale \\.fileManager (file present)")
    func liveClientSeesPresentFileBuiltUnderFalseMock() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptk-livevalue-present-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: dir.appendingPathComponent("corpus.json"))
        defer { try? FileManager.default.removeItem(at: dir) }

        // Construct the live client while a mock fileManager (fileExists → false) is active.
        let client = withDependencies {
            $0.fileManager = FileManagerClient(fileExists: { _ in false })
        } operation: {
            CorpusPersistenceClientKey.liveValue
        }

        // Invoke ambiently — NO override — so a captured stale mock would show through.
        let result = client.exists(dir)

        #expect(result == true, "live client reused a construction-time \\.fileManager mock")
    }

    /// Symmetric: built under a `fileExists → true` mock, then invoked ambiently against a
    /// directory with NO `corpus.json`. The fix consults the live filesystem → `false`;
    /// the pre-fix code reuses the captured `true` mock → `true`.
    @Test("live corpus client does not capture a stale \\.fileManager (file absent)")
    func liveClientSeesAbsentFileBuiltUnderTrueMock() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptk-livevalue-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Intentionally do NOT create corpus.json.
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = withDependencies {
            $0.fileManager = FileManagerClient(fileExists: { _ in true })
        } operation: {
            CorpusPersistenceClientKey.liveValue
        }

        let result = client.exists(dir)

        #expect(result == false, "live client reused a construction-time \\.fileManager mock")
    }
}
