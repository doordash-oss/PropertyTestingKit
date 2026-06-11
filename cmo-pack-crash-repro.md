# Compiler crash: CrossModuleOptimization aborts on pack-generic `makeEvaluator`

Release-mode builds of PropertyTestingKit crash the patched `swift-frontend` in the
CrossModuleOptimization (CMO) pass. Debug/test builds are unaffected. This blocks
`./scripts/run-benchmarks.sh` (it builds the package in release with
`-enable-default-cmo`).

- **Toolchain:** Swift version 6.3.2-dev (LLVM 4e6cdf5caf79efb, Swift f2cbfe2344f3e51)
  at `$BUILD_ROOT/swift-macosx-arm64/bin/swift-frontend`
- **Pre-existing:** reproduced unchanged at PR #35 head `2dd0a64` in a clean worktree
  (i.e. present before the 2026-06-10 review-fix commits).
- **Assert:** `Abort: function forAbstract at ASTContext.cpp:5924` — "Abstract
  conformance with bad subject type" on an `element_type` wrapping the
  `pack_archetype_type` `each Input` (Codable & Sendable), i.e. PropertyTestingKit's
  pack-generic `CoverageStrategy.makeEvaluator<each Input>()` shape, hit while
  `CrossModuleOptimization::canSerializeFunction` clones a `try_apply` and substitutes
  its substitution map.

## Repro

```sh
cd ~/Documents/Swift/PropertyTestingKit
export BUILD_ROOT=/Users/fnord/Documents/OpenSourceDev/build/Ninja-RelWithDebInfoAssert
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export BENCHMARK_DISABLE_JEMALLOC=true   # unrelated: jemalloc isn't installed
./scripts/run-benchmarks.sh --filter "fuzz(Int) onEdge observer - iterations/sec"
```

Crashes while compiling the `PropertyTestingKit` module in release. The essence of
the failing frontend invocation (full ~12 KB command in the crash log's frame 0;
the `-o` list and source list are elided here):

```
swift-frontend -frontend -c <all Sources/PropertyTestingKit/**.swift> \
  -target arm64-apple-macosx26.0 -swift-version 6 -O -enable-default-cmo \
  -module-name PropertyTestingKit -package-name propertytestingkit \
  -num-threads 10 ...
```

`-enable-default-cmo` is the trigger: the same sources build fine in debug
(`./scripts/build-local-toolchain.sh test`) and presumably in release without CMO.

## Crash output

```
Abort: function forAbstract at ASTContext.cpp:5924
Abstract conformance with bad subject type:
(element_type level=1
  (pack=pack_archetype_type address=0x15822aa80 conforms_to="Swift.(file).Decodable" conforms_to="Swift.(file).Encodable" conforms_to="Swift.(file).Sendable" name="each Input"
    (interface_type=generic_type_param_type depth=0 index=0 name="Input" param_kind=pack)))

1.	Swift version 6.3.2-dev (LLVM 4e6cdf5caf79efb, Swift f2cbfe2344f3e51)
2.	Compiling with the current language version
3.	While evaluating request ExecuteSILPipelineRequest(Run pipelines { PrepareOptimizationPasses, EarlyModulePasses, HighLevel,Function+EarlyLoopOpt, HighLevel,Module+StackPromote, MidLevel,Function, ClosureSpecialize, LowLevel,Function, LateLoopOpt, SIL Debug Info Generator } on SIL for PropertyTestingKit)
4.	While running pass #352214 SILModuleTransform "CrossModuleOptimization".
5.	Abort: function forAbstract at ASTContext.cpp:5924
```

## Stack trace

(Nearest-symbol approximations where the offset is `+ 0` — frames 6–8 are really the
abort plumbing into `SubstitutionMapWithLocalArchetypes::operator()`.)

```
0  swift-frontend           0x000000010846e924 llvm::sys::PrintStackTrace(llvm::raw_ostream&, int) + 56
1  swift-frontend           0x000000010846cabc llvm::sys::RunSignalHandlers() + 172
2  swift-frontend           0x000000010846f3d8 SignalHandler(int, __siginfo*, void*) + 312
3  libsystem_platform.dylib 0x000000019a0c6de4 _sigtramp + 56
4  libsystem_pthread.dylib  0x000000019a08ff70 pthread_kill + 288
5  libsystem_c.dylib        0x0000000199f9c908 abort + 128
6  swift-frontend           0x0000000104098dd0 CONDITIONAL_ASSERT_enabled() + 0
7  swift-frontend           0x0000000104098e98 _ABORT(char const*, int, char const*, llvm::StringRef) + 0
8  swift-frontend           0x0000000103c23dbc swift::AvailabilityContext::Storage::get(swift::AvailabilityRange const&, bool, llvm::ArrayRef<swift::AvailabilityContext::DomainInfo>, swift::ASTContext const&) + 0
9  swift-frontend           0x0000000102cda8dc swift::SubstitutionMapWithLocalArchetypes::operator()(swift::InFlightSubstitution&, swift::Type, swift::ProtocolDecl*) + 244
10 swift-frontend           0x0000000103fd9e24 swift::InFlightSubstitution::lookupConformance(swift::Type, swift::ProtocolDecl*, unsigned int) + 52
11 swift-frontend           0x0000000103f17f2c swift::ProtocolConformanceRef::subst(swift::InFlightSubstitution&) const + 704
12 swift-frontend           0x0000000103efa350 void llvm::function_ref<void (swift::Type)>::callback_fn<swift::PackConformance::subst(swift::InFlightSubstitution&) const::$_0>(long, swift::Type) + 104
13 swift-frontend           0x0000000103efa2d8 void llvm::function_ref<void (swift::Type)>::callback_fn<swift::InFlightSubstitution::expandPackExpansionType(swift::PackExpansionType*, llvm::function_ref<void (swift::Type)>)::'lambda'(swift::Type)>(long, swift::Type) + 88
14 swift-frontend           0x0000000103fd94d0 swift::InFlightSubstitution::expandPackExpansionShape(swift::Type, llvm::function_ref<void (swift::Type)>) + 1000
15 swift-frontend           0x0000000103ef9e08 swift::PackConformance::subst(swift::InFlightSubstitution&) const + 224
16 swift-frontend           0x0000000103fa0594 swift::SubstitutionMap::subst(swift::InFlightSubstitution&) const + 596
17 swift-frontend           0x0000000103f0d16c swift::ProtocolConformance::subst(swift::InFlightSubstitution&) const + 148
18 swift-frontend           0x0000000103fa0594 swift::SubstitutionMap::subst(swift::InFlightSubstitution&) const + 596
19 swift-frontend           0x0000000103f0d16c swift::ProtocolConformance::subst(swift::InFlightSubstitution&) const + 148
20 swift-frontend           0x0000000103fa0594 swift::SubstitutionMap::subst(swift::InFlightSubstitution&) const + 596
21 swift-frontend           0x0000000103fa008c swift::SubstitutionMap::subst(llvm::function_ref<swift::Type (swift::SubstitutableType*)>, llvm::function_ref<swift::ProtocolConformanceRef (swift::InFlightSubstitution&, swift::Type, swift::ProtocolDecl*)>, swift::SubstOptions) const + 216
22 swift-frontend           0x00000001033449cc swift::SILCloner<(anonymous namespace)::InstructionVisitor>::getOpSubstitutionMap(swift::SubstitutionMap) + 112
23 swift-frontend           0x000000010333f238 swift::SILCloner<(anonymous namespace)::InstructionVisitor>::visitTryApplyInst(swift::TryApplyInst*) + 164
24 swift-frontend           0x0000000103333880 (anonymous namespace)::CrossModuleOptimization::canSerializeFunction(swift::SILFunction*, llvm::DenseMap<swift::SILFunction*, bool, llvm::DenseMapInfo<swift::SILFunction*, void>, llvm::detail::DenseMapPair<swift::SILFunction*, bool>>&, int) + 724
25 swift-frontend           0x0000000103333034 (anonymous namespace)::CrossModuleOptimizationPass::run() + 628
26 swift-frontend           0x000000010349fbdc swift::SILPassManager::runModulePass(unsigned int) + 876
27 swift-frontend           0x00000001034a265c swift::SILPassManager::execute() + 632
28 swift-frontend           0x000000010349c5f0 swift::SILPassManager::executePassPipelinePlan(swift::SILPassPipelinePlan const&) + 72
29 swift-frontend           0x000000010349c58c swift::ExecuteSILPipelineRequest::evaluate(swift::Evaluator&, swift::SILPipelineExecutionDescriptor) const + 52
30 swift-frontend           0x00000001034c6590 swift::SimpleRequest<swift::ExecuteSILPipelineRequest, std::__1::tuple<> (swift::SILPipelineExecutionDescriptor), (swift::RequestFlags)1>::evaluateRequest(swift::ExecuteSILPipelineRequest const&, swift::Evaluator&) + 28
31 swift-frontend           0x00000001034a90f8 swift::Evaluator::getResultUncached<swift::ExecuteSILPipelineRequest, ...>(...)::'lambda'()::operator()() const + 72
32 swift-frontend           0x00000001034a906c swift::Evaluator::getResultUncached<swift::ExecuteSILPipelineRequest, ...>(...) + 176
33 swift-frontend           0x000000010349c7e0 swift::executePassPipelinePlan(swift::SILModule*, swift::SILPassPipelinePlan const&, bool, swift::irgen::IRGenModule*) + 64
34 swift-frontend           0x00000001034aac44 swift::runSILOptimizationPasses(swift::SILModule&) + 180
35 swift-frontend           0x00000001029b871c swift::CompilerInstance::performSILProcessing(swift::SILModule*) + 628
36 swift-frontend           0x00000001026e6f4c performCompileStepsPostSILGen(...) + 796
37 swift-frontend           0x00000001026e6af4 swift::performCompileStepsPostSema(...) + 2764
38 swift-frontend           0x00000001026f6ad8 withSemanticAnalysis(...) + 164
39 swift-frontend           0x00000001026ea1b0 performCompile(...) + 560
40 swift-frontend           0x00000001026e7d54 swift::performFrontend(llvm::ArrayRef<char const*>, char const*, void*, swift::FrontendObserver*) + 2440
41 swift-frontend           0x000000010244dd04 swift::mainEntry(int, char const**) + 3244
42 dyld                     0x0000000199d10274 start + 2840
```

## Reading of the trace

CMO walks `try_apply` instructions while deciding whether a function can be
serialized for cross-module inlining (frame 24 `canSerializeFunction` → frame 23
`visitTryApplyInst` → frame 22 `getOpSubstitutionMap`). Substituting the apply's
substitution map recurses through nested `ProtocolConformance::subst` (frames
16–20) into `PackConformance::subst`, which expands the pack expansion and asks
for a conformance on an `element_type` of the pack archetype `each Input`
(frames 12–15). `SubstitutionMapWithLocalArchetypes` (frame 9, the SILCloner's
substitution callback) falls into `ProtocolConformanceRef::forAbstract`, whose
sanity check rejects the element type as a subject (`ASTContext.cpp:5924`).

Likely culprit shape in PropertyTestingKit: the throwing call inside the
pack-generic evaluator —
`CoverageStrategy.makeEvaluator<each Input: Codable & Sendable>()` building a
`CoverageEvaluator<repeat each Input>` whose `evaluate` closure contains
`try? client.snapshotCoveredArraysWithContext(context)` (a `try_apply` inside a
function with a pack archetype in scope).

Full raw log: `/tmp/t113-bench2.log` (current head), `/tmp/t113-baseline.log`
(clean worktree at `2dd0a64`, identical abort).
