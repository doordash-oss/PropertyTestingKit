// swift-tools-version: 6.0
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
        .package(url: "https://github.com/alex-reilly-dd/LLVMCoverageKit.git", from: "18.1.8"),
    ],
    targets: [
        // C module for LLVM profile runtime interface
        .target(
            name: "PropertyTestingKitInternals",
            path: "Sources/PropertyTestingKitInternals"
        ),

        // C++ wrapper for LLVM coverage APIs
        .target(
            name: "LLVMCoverageInterop",
            dependencies: ["LLVMCoverageKit"],
            path: "Sources/LLVMCoverageInterop",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("__STDC_CONSTANT_MACROS"),
                .define("__STDC_FORMAT_MACROS"),
                .define("__STDC_LIMIT_MACROS"),
                .unsafeFlags(["-std=c++17", "-fno-exceptions", "-fno-rtti"])
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),

        .target(
            name: "PropertyTestingKit",
            dependencies: [
                "PropertyTestingKitMacros",
                "PropertyTestingKitInternals",
                "LLVMCoverageInterop"
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "PropertyTestingKitTests",
            dependencies: ["PropertyTestingKit"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .macro(
            name: "PropertyTestingKitMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
