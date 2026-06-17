// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// Compile-time coverage instrumentation is provided by two out-of-tree LLVM
// pass plugins (sources in LLVMPasses/, built by scripts/build-llvm-plugins.sh
// into .build/llvm-plugins). They replace the former runtime filters that used
// to live in SanCovHooks.c:
//   TagCompilerGenerated — tags compiler-generated functions NoSanitizeCoverage
//                          so SanCov emits no edge/cmp guards for them (compile-
//                          time edge filter; async resume/yield edges stay out,
//                          preserving pathTrie determinism). MUST load first so
//                          EmitCmpTrace also skips those functions.
//   EmitCmpTrace         — emits __sanitizer_cov_trace_cmp* ourselves for the
//                          comparisons we want, dropping trap-guard cmps
//                          (bounds/overflow/precondition). Used INSTEAD of
//                          `-sanitize-coverage=…,trace-cmp`.
// build-local-toolchain.sh builds the plugins before compiling; for a raw
// `swift build` run scripts/build-llvm-plugins.sh first.
let pluginDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent(".build/llvm-plugins")
func loadPass(_ name: String) -> [String] {
    ["-Xfrontend", "-load-pass-plugin=\(pluginDir.appendingPathComponent(name + ".dylib").path)"]
}

// Edge coverage with the compile-time compiler-generated filter.
let edgeCoverage: [String] =
    ["-sanitize=undefined", "-sanitize-coverage=edge,pc-table"] + loadPass("TagCompilerGenerated")
// Edge + comparison coverage (the cmp channel via EmitCmpTrace, not stock trace-cmp).
let edgeCmpCoverage: [String] = edgeCoverage + loadPass("EmitCmpTrace")

let package = Package(
    name: "PropertyTestingKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "PropertyTestingKit",
            targets: ["PropertyTestingKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.6.0"),
        .package(url: "https://github.com/twof/FunctionSpy.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/pointfreeco/swift-clocks.git", from: "1.0.0"),
        .package(url: "https://github.com/alex-reilly-dd/package-benchmark.git", branch: "runtime_forwarding"),
    ],
    targets: [
        // C module for SanitizerCoverage hooks
        .target(
            name: "SanCovHooks",
            path: "Sources/SanCovHooks",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3"])  // Optimize hot path even in debug builds
            ]
        ),

        // LLVM-based symbolizer for DWARF debug info parsing
        .target(
            name: "CLLVMSymbolizer",
            path: "Sources/CLLVMSymbolizer",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-O3",  // Optimize even in debug builds
                    "-I/opt/homebrew/opt/llvm/include",
                    "-std=c++17",
                    "-fno-exceptions",
                    "-fno-rtti",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/llvm/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/opt/llvm/lib",
                ]),
                .linkedLibrary("LLVM"),
            ]
        ),

        .target(
            name: "EdgeHooks",
            dependencies: [
                "SanCovHooks",
            ]
            // No -sanitize-coverage: functions here are safe to use as edge hooks
        ),

        // C helpers for reading Swift runtime ABI (job flags, task locals, actor pointers)
        .target(
            name: "CScheduleHooks",
            path: "Sources/CScheduleHooks",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3"])  // Optimize hot path even in debug builds
            ]
        ),

        // Schedule control for concurrency fuzzing — intercepts swift_task_enqueueGlobal_hook
        // No -sanitize-coverage to avoid instrumenting the hook itself
        .target(
            name: "ScheduleControl",
            dependencies: ["CScheduleHooks", "SanCovHooks"],
            swiftSettings: [
                .unsafeFlags(["-O"])  // Optimize even in debug builds
            ]
        ),

        .target(
            name: "PropertyTestingKit",
            dependencies: [
                "SanCovHooks",
                "EdgeHooks",
                "ScheduleControl",
                "CLLVMSymbolizer",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                // .unsafeFlags(["-O"])  // Optimize even in debug builds
            ]
        ),
        .testTarget(
            name: "PropertyTestingKitTests",
            dependencies: [
                "PropertyTestingKit",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "FunctionSpy", package: "FunctionSpy"),
            ],
            exclude: ["Corpus", "Fuzzing/Corpus"],
            swiftSettings: [
                // edge + comparison coverage; the cmp channel (via EmitCmpTrace)
                // lets the input-to-state integration tests exercise the real cmp
                // hooks (FuzzInputToStateTests fuzzes a magic-value SUT in-target).
                .unsafeFlags(edgeCmpCoverage)
            ]
        ),
        .testTarget(
            name: "ScheduleControlTests",
            dependencies: [
                "ScheduleControl",
                "PropertyTestingKit",
                "GenericTimerPoller",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            swiftSettings: [
                .unsafeFlags(edgeCoverage)
            ]
        ),
        .testTarget(
            name: "ScratchPad",
            dependencies: [
                "PropertyTestingKit",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "FunctionSpy", package: "FunctionSpy"),
            ],
            exclude: ["Corpus"],
            swiftSettings: [
                .unsafeFlags(edgeCoverage)
            ]
        ),
        .testTarget(
            name: "SanCovTests",
            dependencies: [
                "SanCovHooks",
                "PropertyTestingKit",
            ],
            swiftSettings: [
                // Enable sanitizer coverage for thread-local coverage testing
                .unsafeFlags(edgeCoverage)
            ]
        ),
        // TSanTests: Race condition tests that exercise concurrent code paths.
        // To actually run with ThreadSanitizer, use: ./scripts/run-tsan-tests.sh
        // The script handles DYLD_INSERT_LIBRARIES which is required for TSan on macOS.
        // These tests can also run without TSan to verify concurrent code doesn't crash.
        .testTarget(
            name: "TSanTests",
            dependencies: [
                "PropertyTestingKit",
            ]
        ),

        // GenericTimerPoller — production code under test
        // Swift 5 language mode to match production compilation (actor isolation warnings, not errors)
        .target(
            name: "GenericTimerPoller",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(edgeCoverage)
            ]
        ),
        .testTarget(
            name: "GenericTimerPollerTests",
            dependencies: [
                "GenericTimerPoller",
                "PropertyTestingKit",
                "ScheduleControl",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
    ]
)

// Benchmark of CoverageBenchmarks
package.targets += [
    .executableTarget(
        name: "CoverageBenchmarks",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "PropertyTestingKit",
        ],
        path: "Benchmarks/CoverageBenchmarks",
        exclude: ["Corpus"],
        swiftSettings: [
            // Enable sanitizer coverage so we have realistic counter counts
            // Note: sanitize-coverage requires a sanitizer to be enabled
            .unsafeFlags(["-O"] + edgeCoverage)
        ],
        linkerSettings: [
            // Add rpath for Testing.framework from Xcode (needed for local toolchain)
            .unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
            ])
        ],
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
        ]
    ),
    .executableTarget(
        name: "ProfiledBenchmark",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "PropertyTestingKit",
        ],
        path: "Benchmarks/ProfiledBenchmark",
        swiftSettings: [
            // edge + comparison coverage (cmp channel via EmitCmpTrace) so the
            // benchmark closure's integer comparisons dispatch through
            // sancov_dispatch_cmp → the boundary observer, exercising the
            // per-comparison hot path under profiling.
            .unsafeFlags(["-O"] + edgeCmpCoverage)
        ],
        linkerSettings: [
            // Add rpath for Testing.framework from Xcode (needed for local toolchain)
            .unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
            ])
        ],
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
        ]
    )
]
