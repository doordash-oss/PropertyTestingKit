// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

// LLVM 18 paths from Homebrew installation (Apple's Swift 6.2 uses Coverage Mapping Version 7 from LLVM 18)
let llvmPath = "/opt/homebrew/opt/llvm@18"
let llvmInclude = "\(llvmPath)/include"
let llvmLib = "\(llvmPath)/lib"

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
            path: "Sources/LLVMCoverageInterop",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("__STDC_CONSTANT_MACROS"),
                .define("__STDC_FORMAT_MACROS"),
                .define("__STDC_LIMIT_MACROS"),
                .unsafeFlags(["-std=c++17", "-fno-exceptions", "-I\(llvmInclude)"])
            ],
            linkerSettings: [
                .linkedLibrary("LLVM"),
                .unsafeFlags(["-L\(llvmLib)"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", llvmLib])
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
            // Note: Profile runtime is automatically linked by Swift when using --enable-code-coverage
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
