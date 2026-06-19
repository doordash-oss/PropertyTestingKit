// Out-of-tree LLVM pass plugin: tag compiler-generated Swift functions with
// `nosanitize_coverage` BEFORE SanitizerCoverage runs, so SanCov emits no edge
// guards / pc-table entries (and no cmp callbacks) for them. This replaces the
// RUNTIME edge filter (SanCovHooks.c: g_edge_state / sancov_apply_edge_filter /
// sancov_is_compiler_generated) with a compile-time decision.
//
// The name patterns are ported verbatim from sancov_is_compiler_generated.
// MUST run at OptimizerLast (after coroutine splitting, so async funclet names
// like ...TQ3_ exist) and before SanitizerCoverage (plugin EP callbacks are
// registered ahead of Swift's, so this pass runs first at OptimizerLast).

#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/Compiler.h"

using namespace llvm;

namespace {

// Verbatim port of SanCovHooks.c `sancov_is_compiler_generated`, operating on
// the function's mangled name. Async continuation edges (T[QY]<n>_) are filtered
// for pathTrie determinism, not just noise — keep parity exact.
static bool isCompilerGenerated(StringRef N) {
  if (N.starts_with("__swift_"))
    return true;
  if (N.starts_with("_swift_"))
    return true;
  size_t len = N.size();
  if (len < 3)
    return false;

  if (N.ends_with("Wl") || N.ends_with("WL") || N.ends_with("Ma"))
    return true;
  // WO + specifier (all outlined operations: WOh/c/d/r/b/e/...)
  if (N[len - 3] == 'W' && N[len - 2] == 'O')
    return true;
  if (N.ends_with("TA") || N.ends_with("TR") || N.ends_with("TK") ||
      N.ends_with("Mr"))
    return true;
  if (N.contains("TATQ") || N.contains("TATY") || N.contains("TRTQ") ||
      N.contains("TRTY"))
    return true;
  // global/static variable addressor
  if (N.ends_with("vau"))
    return true;

  // bare async resume/yield: ...T[QY]<digits>_
  if (len >= 4 && N[len - 1] == '_') {
    size_t p = len - 2;
    while (p > 0 && N[p] >= '0' && N[p] <= '9')
      --p;
    if (p >= 1 && (N[p] == 'Q' || N[p] == 'Y') && N[p - 1] == 'T')
      return true;
  }

  // default argument generator: ...fA_ or ...fA<digit>_
  if (N[len - 3] == 'f' && N[len - 2] == 'A' && N[len - 1] == '_')
    return true;
  if (len >= 4 && N[len - 4] == 'f' && N[len - 3] == 'A' && N[len - 1] == '_')
    return true;

  return false;
}

struct TagCompilerGenerated : PassInfoMixin<TagCompilerGenerated> {
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &) {
    for (Function &F : M) {
      if (F.isDeclaration())
        continue;
      if (F.hasFnAttribute(Attribute::NoSanitizeCoverage))
        continue;
      if (isCompilerGenerated(F.getName()))
        F.addFnAttr(Attribute::NoSanitizeCoverage);
    }
    // Only function attributes change; no IR/CFG mutation.
    return PreservedAnalyses::all();
  }
};

} // namespace

extern "C" LLVM_ATTRIBUTE_WEAK ::llvm::PassPluginLibraryInfo
llvmGetPassPluginInfo() {
  return {LLVM_PLUGIN_API_VERSION, "TagCompilerGenerated", "0.1",
          [](PassBuilder &PB) {
            PB.registerOptimizerLastEPCallback(
                [](ModulePassManager &MPM, OptimizationLevel,
                   ThinOrFullLTOPhase) { MPM.addPass(TagCompilerGenerated()); });
          }};
}
