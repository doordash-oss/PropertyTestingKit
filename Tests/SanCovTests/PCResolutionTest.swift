import Testing
import Foundation
import SanCovHooks


@Suite("PC Resolution")
struct PCResolutionTest {

    @Test("Edge filter catches bare async resume/yield patterns (TQ, TY suffixes)")
    func filterCatchesAsyncResumeYield() {
        // TQ = async resume, TY = async yield. These are compiler-generated
        // continuation points that vary between runs.
        let asyncPatterns = [
            "$s20SomeModule10someFunc1yyYaKFTQ3_",     // bare TQ (resume point 3)
            "$s20SomeModule10someFunc1yyYaKFTY4_",     // bare TY (yield point 4)
            "$s20SomeModule10someFunc1yyYaKFTQ0_",     // TQ0_ (resume point 0)
            "$s20SomeModule10someFunc1yyYaKFTY1_",     // TY1_ (yield point 1)
            "$s20SomeModule10closureYbcfU_TQ0_",       // closure TQ
            "$s20SomeModule10closureYbcfU_TY1_",       // closure TY
        ]

        let nonAsyncPatterns = [
            "$s20SomeModule10someFunc1yyF",              // regular function
            "$s20SomeModule10SomeStructV5countSivg",     // property getter
            "$s20SomeModule10SomeStructV5countSivs",     // property setter
        ]

        for sym in asyncPatterns {
            let result = sym.withCString { sancov_is_compiler_generated($0) }
            #expect(result, "Should filter async pattern: \(sym)")
        }

        for sym in nonAsyncPatterns {
            let result = sym.withCString { sancov_is_compiler_generated($0) }
            #expect(!result, "Should NOT filter: \(sym)")
        }
    }

    @Test("Edge filter catches global variable addressors (vau suffix)")
    func filterCatchesGlobalAddressors() {
        let addressorPatterns = [
            "$s20SomeModule8lane1OpsSayAA8PollerOpOGvau",     // global let addressor
            "$s20SomeModule13scheduleBytesS5UInt8VGvau",       // static let addressor
        ]

        let nonAddressorPatterns = [
            "$s20SomeModule8lane1OpsSayAA8PollerOpOGvg",     // getter (not addressor)
        ]

        for sym in addressorPatterns {
            let result = sym.withCString { sancov_is_compiler_generated($0) }
            #expect(result, "Should filter addressor: \(sym)")
        }

        for sym in nonAddressorPatterns {
            let result = sym.withCString { sancov_is_compiler_generated($0) }
            #expect(!result, "Should NOT filter: \(sym)")
        }
    }

    @Test("All guard indices have resolvable PCs")
    func allGuardsHavePCs() {
        let totalGuards = Int(sancov_get_counter_count())
        #expect(totalGuards > 0, "Should have guards registered")

        var resolved = 0
        var unresolved = 0
        var firstUnresolved: Int?

        for i in 0..<totalGuards {
            let pc = sancov_get_pc(i)
            if pc != 0 {
                resolved += 1
            } else {
                unresolved += 1
                if firstUnresolved == nil { firstUnresolved = i }
            }
        }

        print("Total guards: \(totalGuards)")
        print("Resolved: \(resolved), Unresolved: \(unresolved)")
        if let first = firstUnresolved {
            print("First unresolved at index: \(first)")
        }

        #expect(
            unresolved == 0,
            "\(unresolved) of \(totalGuards) guards have no PC (first at index \(firstUnresolved ?? -1))"
        )
    }
}
