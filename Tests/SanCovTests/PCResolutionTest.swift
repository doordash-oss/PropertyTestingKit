import Testing
import Foundation
import SanCovHooks


@Suite("PC Resolution")
struct PCResolutionTest {

    // Compiler-generated-edge classification (async resume/yield TQ/TY, vau
    // addressors, outlined ops, thunks) moved to the TagCompilerGenerated LLVM
    // pass plugin, which tags those functions NoSanitizeCoverage at compile time.
    // Its correctness is exercised end-to-end by the determinism tests
    // (CoverageDeterminismTest): if async edges weren't filtered, pathTrie
    // determinism would break. The former runtime classifier
    // (sancov_is_compiler_generated) and its unit tests have been removed.

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
