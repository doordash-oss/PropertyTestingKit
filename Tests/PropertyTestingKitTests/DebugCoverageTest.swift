import Testing
import PropertyTestingKit
import PropertyTestingKitInternals

@Test func debugCoverageRuntime() {
    print("=== Debug Coverage Runtime ===")

    // Check if runtime is available via the header's helper
    let available = ptk_profilerRuntimeAvailable()
    print("ptk_profilerRuntimeAvailable: \(available)")

    // Try to get counters via the inline wrapper functions
    let begin = __llvm_profile_begin_counters()
    let end = __llvm_profile_end_counters()
    print("__llvm_profile_begin_counters: \(String(describing: begin))")
    print("__llvm_profile_end_counters: \(String(describing: end))")

    if let b = begin, let e = end {
        let count = e - b
        print("Counter count: \(count)")
    } else {
        print("Counters are nil - dlsym lookup failed")
    }

    // Check CoverageTrait.isAvailable
    print("CoverageTrait.isAvailable: \(CoverageTrait.isAvailable)")
}
