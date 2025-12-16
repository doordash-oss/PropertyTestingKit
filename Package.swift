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

        .target(
            name: "PropertyTestingKit",
            dependencies: [
                "PropertyTestingKitMacros",
                "ValueProfileHooks",
                "StringAllocationHooks",
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
