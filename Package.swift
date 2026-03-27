// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

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
        .package(path: "../../../Documents/OpenSource/package-benchmark"),
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
            publicHeadersPath: "include"
        ),

        // Schedule control for concurrency fuzzing — intercepts swift_task_enqueueGlobal_hook
        // No -sanitize-coverage to avoid instrumenting the hook itself
        .target(
            name: "ScheduleControl",
            dependencies: ["CScheduleHooks", "SanCovHooks"]
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
                .unsafeFlags(["-O"])  // Optimize even in debug builds
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
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,pc-table"
                ])
            ]
        ),
        .testTarget(
            name: "ScheduleControlTests",
            dependencies: [
                "ScheduleControl",
                "PropertyTestingKit",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,pc-table"
                ])
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
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,pc-table"
                ])
            ]
        ),
        .testTarget(
            name: "SanCovTests",
            dependencies: [
                "SanCovHooks",
            ],
            swiftSettings: [
                // Enable sanitizer coverage for thread-local coverage testing
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge"
                ])
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

        // IFC machine benchmark library — port of FuzzChick's secure machine
        .target(
            name: "IFCMachine",
            dependencies: ["PropertyTestingKit"],
            swiftSettings: [
                .unsafeFlags(["-O"])  // Optimize even in debug builds (disables assert)
            ]
        ),
        .testTarget(
            name: "IFCMachineTests",
            dependencies: [
                "IFCMachine",
                "PropertyTestingKit",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,pc-table"
                ])
            ]
        ),
        // IFC benchmark tests — property-based tests that exercise the fuzzer
        // Ported from QuickChick/IFC Driver.v
        .testTarget(
            name: "IFCBenchmarkTests",
            dependencies: [
                "IFCMachine",
                "PropertyTestingKit",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,pc-table"
                ])
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
            ]
        ),
        .testTarget(
            name: "GenericTimerPollerTests",
            dependencies: [
                "GenericTimerPoller",
                "PropertyTestingKit",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,pc-table"
                ])
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
            .unsafeFlags([
                "-O",
                "-sanitize=undefined",
                "-sanitize-coverage=edge,pc-table"
            ])
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
        name: "IFCBenchmarks",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "IFCMachine",
            "PropertyTestingKit",
        ],
        path: "Benchmarks/IFCBenchmarks",
        exclude: ["Corpus"],
        swiftSettings: [
            .unsafeFlags([
                "-O",
                "-sanitize=undefined",
                "-sanitize-coverage=edge,pc-table"
            ])
        ],
        linkerSettings: [
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
            .unsafeFlags([
                "-O",
                "-sanitize=undefined",
                "-sanitize-coverage=edge,pc-table"
            ])
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
