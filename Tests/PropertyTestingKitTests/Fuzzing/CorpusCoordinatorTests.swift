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

//  Tests for corpus-mode policy: load/save/delete, regression replay, and the
//  fuzz-vs-regress decision. This behavior moved out of FuzzEngine (a pure fuzz
//  runner) into the coordinator (`runFuzzCampaign`).
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

@Suite("Corpus Coordinator")
struct CorpusCoordinatorTests {

    @Test("Fuzzing saves the discovered corpus")
    func savesCorpusAfterFuzzing() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-save")
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        let result = await withDependencies {
            $0.coverageCounters = .liveValue
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },   // no corpus → .auto fuzzes
                delete: { _ in }
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 100,
                corpusDir: corpusDir,
                mode: .auto,
                additionalSeeds: [0, 1, -1, 42]
            ) { (_: Int) in }
        }

        #expect(result.corpus.count > 0, "Should have corpus entries")
        #expect(!result.wasRegression, "No corpus exists → fuzz mode")
        #expect(saveSpy.callCount == 1, "Corpus should be saved")
    }

    @Test("Loads existing corpus and runs regression")
    func loadsCorpusAndRegresses() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-regression")
        let corpusData = Data("[[42]]".utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 50,
                corpusDir: corpusDir,
                mode: .auto
            ) { (_: Int) in }
        }

        #expect(existsSpy.callCount >= 1, "Should check if corpus exists")
        #expect(loadSpy.callCount == 1, "Should have loaded corpus")
        #expect(result.corpus.count > 0)
        #expect(result.wasRegression, "Should be regression mode")
        #expect(saveSpy.callCount == 0, "Regression must not re-save the corpus")
    }

    @Test("Corpus load failure falls back to fuzzing")
    func loadFailureFallsBackToFuzzing() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-loadfail")
        let invalidJSON = Data("{ invalid json }".utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in invalidJSON }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 50,
                corpusDir: corpusDir,
                mode: .auto
            ) { (_: Int) in }
        }

        #expect(existsSpy.callCount >= 1)
        #expect(loadSpy.callCount == 1, "Should have attempted to load corpus")
        #expect(!result.wasRegression, "Should fall back to fuzzing mode")
    }

    @Test("Corpus save failure is non-fatal")
    func saveFailureIsNonFatal() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-savefail")
        struct SaveError: Error {}

        let (saveSpy, saveFn) = spy { (_: Data, _: URL) throws -> Void in
            throw SaveError()
        }

        let result = await withDependencies {
            $0.coverageCounters = .liveValue
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },
                delete: { _ in }
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 50,
                corpusDir: corpusDir,
                mode: .auto,
                additionalSeeds: [0, 1, 42]
            ) { (_: Int) in }
        }

        #expect(saveSpy.callCount == 1, "Should have attempted to save corpus")
        #expect(!result.wasRegression)
    }

    @Test("Empty corpus regression succeeds immediately")
    func emptyCorpusRegressionSucceeds() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-regression-empty")
        let corpusData = Data("[]".utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 50,
                corpusDir: corpusDir,
                mode: .auto
            ) { (_: Int) in }
        }

        #expect(existsSpy.callCount >= 1)
        #expect(loadSpy.callCount == 1, "Should have loaded corpus")
        #expect(result.wasRegression, "Should be regression mode with empty corpus")
        #expect(result.failures.isEmpty)
    }

    @Test("Regression captures failures during replay")
    func regressionCapturesFailures() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-regression-fail")
        let corpusData = Data("[[42]]".utf8)

        let (_, loadFn) = spy { (_: URL) -> Data in corpusData }
        struct RegressionError: Error {}

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: { _ in true },
                delete: { _ in }
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 50,
                corpusDir: corpusDir,
                mode: .auto
            ) { (input: Int) in
                if input == 42 {
                    throw RegressionError()
                }
            }
        }

        #expect(result.wasRegression, "Should be regression mode")
        #expect(!result.failures.isEmpty, "Should capture failures during regression")
        #expect(result.failures.first?.input == 42)
    }

    @Test("regressionOnly with no corpus returns empty")
    func regressionOnlyWithNoCorpusIsEmpty() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-regression-only-missing")
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }
        let (loadSpy, loadFn) = spy { (_: URL) -> Data in Data() }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: loadFn,
                exists: { _ in false },   // no corpus
                delete: { _ in }
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 50,
                corpusDir: corpusDir,
                mode: .regressionOnly
            ) { (_: Int) in }
        }

        #expect(result.corpus.entries.isEmpty, "No corpus → nothing to regress")
        #expect(result.failures.isEmpty)
        #expect(loadSpy.callCount == 0, "Should not load when corpus is absent")
        #expect(saveSpy.callCount == 0, "regressionOnly never saves")
    }

    @Test("refuzzReplace deletes the existing corpus before fuzzing")
    func refuzzReplaceDeletesFirst() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-refuzz-replace")
        let (deleteSpy, deleteFn) = spy { (_: URL) in }
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        let result = await withDependencies {
            $0.coverageCounters = .liveValue
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in true },   // a corpus exists and must be deleted
                delete: deleteFn
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 50,
                corpusDir: corpusDir,
                mode: .refuzzReplace,
                additionalSeeds: [0, 1, 42]
            ) { (_: Int) in }
        }

        #expect(deleteSpy.callCount == 1, "Existing corpus should be deleted first")
        #expect(!result.wasRegression, "refuzzReplace always fuzzes")
        #expect(saveSpy.callCount == 1, "Fresh corpus should be saved")
    }

    @Test("refuzzExtend replays the saved corpus as seeds while fuzzing")
    func refuzzExtendReplaysCorpusAsSeeds() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/coord-refuzz-extend")
        let corpusData = Data("[[42]]".utf8)
        let replayed = SyncBox<[Int]>([])

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        let result = await withDependencies {
            $0.coverageCounters = .liveValue
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: loadFn,
                exists: { _ in true },
                delete: { _ in }
            )
        } operation: {
            await runCoordinatorWithMaxIterations(
                maxIterations: 50,
                corpusDir: corpusDir,
                mode: .refuzzExtend
            ) { (input: Int) in
                replayed.update { $0.append(input) }
            }
        }

        #expect(loadSpy.callCount == 1, "Should load the corpus to extend")
        #expect(!result.wasRegression, "refuzzExtend fuzzes (does not regress)")
        #expect(replayed.value.contains(42), "Loaded corpus input should be replayed as a seed")
        #expect(saveSpy.callCount == 1, "Extended corpus should be saved")
    }
}
