// Out-of-tree LLVM pass plugin: emit __sanitizer_cov_trace_cmp* callbacks
// ourselves for the comparisons we care about, replacing SanitizerCoverage's
// trace-cmp emission. Build the SUT with `-sanitize-coverage=edge,pc-table`
// (NO trace-cmp) and load this plugin; it emits cmp callbacks for every integer
// comparison EXCEPT trap guards (bounds / overflow / precondition checks, whose
// branch reaches `unreachable`). Faithful to InjectTraceForCmp otherwise.

#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/Compiler.h"

using namespace llvm;

namespace {

// True iff following single-successor edges from BB reaches an `unreachable`
// terminator within MaxDepth hops. Swift lowers cond_fail (bounds/overflow/
// precondition checks) to a branch whose failure edge runs — directly or via an
// empty split critical edge + shared trap merge block — into a
// _fatalErrorMessage/llvm.trap block ending in `unreachable`.
static bool reachesUnreachable(const BasicBlock *BB, unsigned MaxDepth) {
  for (unsigned I = 0; BB && I <= MaxDepth; ++I) {
    if (isa<UnreachableInst>(BB->getTerminator()))
      return true;
    BB = BB->getSingleSuccessor();
  }
  return false;
}

static bool isTrapGuard(ICmpInst *CMP) {
  if (!CMP->hasOneUse())
    return false;
  auto *BR = dyn_cast<BranchInst>(CMP->user_back());
  if (!BR || !BR->isConditional())
    return false;
  for (BasicBlock *Succ : BR->successors())
    if (reachesUnreachable(Succ, /*MaxDepth=*/3))
      return true;
  return false;
}

struct EmitCmpTrace : PassInfoMixin<EmitCmpTrace> {
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &) {
    LLVMContext &Ctx = M.getContext();
    const DataLayout &DL = M.getDataLayout();
    Type *VoidTy = Type::getVoidTy(Ctx);
    IntegerType *IntTys[4] = {Type::getInt8Ty(Ctx), Type::getInt16Ty(Ctx),
                              Type::getInt32Ty(Ctx), Type::getInt64Ty(Ctx)};
    const char *CmpNames[4] = {
        "__sanitizer_cov_trace_cmp1", "__sanitizer_cov_trace_cmp2",
        "__sanitizer_cov_trace_cmp4", "__sanitizer_cov_trace_cmp8"};
    const char *ConstNames[4] = {"__sanitizer_cov_trace_const_cmp1",
                                 "__sanitizer_cov_trace_const_cmp2",
                                 "__sanitizer_cov_trace_const_cmp4",
                                 "__sanitizer_cov_trace_const_cmp8"};
    FunctionCallee CmpFn[4], ConstFn[4];
    for (int i = 0; i < 4; ++i) {
      FunctionType *FT = FunctionType::get(VoidTy, {IntTys[i], IntTys[i]}, false);
      CmpFn[i] = M.getOrInsertFunction(CmpNames[i], FT);
      ConstFn[i] = M.getOrInsertFunction(ConstNames[i], FT);
    }

    bool Changed = false;
    for (Function &F : M) {
      if (F.isDeclaration())
        continue;
      if (F.getName().starts_with("__sanitizer_"))
        continue;
      if (F.hasFnAttribute(Attribute::NoSanitizeCoverage))
        continue;

      SmallVector<ICmpInst *, 16> Targets;
      for (BasicBlock &BB : F)
        for (Instruction &I : BB)
          if (auto *CMP = dyn_cast<ICmpInst>(&I))
            if (!isTrapGuard(CMP))
              Targets.push_back(CMP);

      for (ICmpInst *CMP : Targets) {
        Value *A0 = CMP->getOperand(0);
        Value *A1 = CMP->getOperand(1);
        if (!A0->getType()->isIntegerTy())
          continue;
        uint64_t TS = DL.getTypeStoreSizeInBits(A0->getType());
        int Idx = TS == 8 ? 0 : TS == 16 ? 1 : TS == 32 ? 2 : TS == 64 ? 3 : -1;
        if (Idx < 0)
          continue;
        bool C0 = isa<ConstantInt>(A0), C1 = isa<ConstantInt>(A1);
        if (C0 && C1)
          continue; // both const: nothing to learn
        FunctionCallee Fn = CmpFn[Idx];
        if (C0 || C1) {
          Fn = ConstFn[Idx];
          if (C1)
            std::swap(A0, A1); // const goes first, matching SanCov
        }
        IRBuilder<> IRB(CMP);
        Type *Ty = IntTys[Idx];
        IRB.CreateCall(Fn, {IRB.CreateIntCast(A0, Ty, /*isSigned=*/true),
                            IRB.CreateIntCast(A1, Ty, /*isSigned=*/true)});
        Changed = true;
      }
    }
    return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
  }
};

} // namespace

extern "C" LLVM_ATTRIBUTE_WEAK ::llvm::PassPluginLibraryInfo
llvmGetPassPluginInfo() {
  return {LLVM_PLUGIN_API_VERSION, "EmitCmpTrace", "0.1",
          [](PassBuilder &PB) {
            PB.registerOptimizerLastEPCallback(
                [](ModulePassManager &MPM, OptimizationLevel,
                   ThinOrFullLTOPhase) { MPM.addPass(EmitCmpTrace()); });
          }};
}
