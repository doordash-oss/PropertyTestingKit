// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "PropertyTestingKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "PropertyTestingKit",
            targets: ["PropertyTestingKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.6.0"),
        .package(url: "https://github.com/twof/FunctionSpy.git", from: "1.2.0"),
        .package(url: "https://github.com/ordo-one/package-benchmark.git", from: "1.4.0"),
    ],
    targets: [
        // C module for value profile hooks (sanitizer coverage)
        .target(
            name: "ValueProfileHooks",
            path: "Sources/ValueProfileHooks",
            publicHeadersPath: "include"
        ),

        // C module for string allocation hooks (fishhook-based)
        .target(
            name: "StringAllocationHooks",
            path: "Sources/StringAllocationHooks",
            publicHeadersPath: "include"
        ),

        // LLVM-based symbolizer for DWARF debug info parsing
        .target(
            name: "CLLVMSymbolizer",
            path: "Sources/CLLVMSymbolizer",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
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
            name: "PropertyTestingKit",
            dependencies: [
                "PropertyTestingKitMacros",
                "ValueProfileHooks",
                "StringAllocationHooks",
                "CLLVMSymbolizer",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .testTarget(
            name: "PropertyTestingKitTests",
            dependencies: [
                "PropertyTestingKit",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "FunctionSpy", package: "FunctionSpy"),
            ],
            swiftSettings: [
                // Enable sanitizer coverage for SanCov source mapping tests
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,trace-cmp,pc-table"
                ])
            ]
        ),
        .testTarget(
            name: "StressTests",
            dependencies: [
                "PropertyTestingKit",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: [
                // Enable value profile guidance for stress tests
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,trace-cmp"
                ])
            ]
        ),
        .testTarget(
            name: "SanCovTests",
            dependencies: [
                "ValueProfileHooks",
            ],
            swiftSettings: [
                // Enable sanitizer coverage for thread-local coverage testing
                .unsafeFlags([
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,trace-cmp"
                ])
            ]
        ),
        .macro(
            name: "PropertyTestingKitMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        )
    ]
)

// Benchmark of CoverageBenchmarks
// Note: This target intentionally only depends on ValueProfileHooks (not PropertyTestingKit)
// because PropertyTestingKit uses parameter packs which crash the Swift 6.2 compiler in release mode.
// The benchmark includes its own minimal implementations of the types being benchmarked.
package.targets += [
    .executableTarget(
        name: "CoverageBenchmarks",
        dependencies: [
            .product(name: "Benchmark", package: "package-benchmark"),
            "ValueProfileHooks",
        ],
        path: "Benchmarks/CoverageBenchmarks",
        swiftSettings: [
            // Enable sanitizer coverage so we have realistic counter counts
            // Note: sanitize-coverage requires a sanitizer to be enabled
            .unsafeFlags([
                "-sanitize=undefined",
                "-sanitize-coverage=edge,trace-cmp,pc-table"
            ])
        ],
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
        ]
    ),
]