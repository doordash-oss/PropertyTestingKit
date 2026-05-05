// scripts/runtests.swift
//
// Bypass `swift test --skip-build` (~4.4s/iter overhead from SwiftPM
// dependency-graph evaluation) to run a swift-testing bundle directly.
//
// Usage (via the runtests.sh wrapper which sets DYLD search paths):
//   BUNDLE_PATH=<path-to-bundle-binary> runtests --testing-library swift-testing [--filter X ...]
//
// The shim:
//   - dlopens the bundle (path comes from BUNDLE_PATH env so the shim's own
//     argv stays clean for swift-testing's CLI to parse).
//   - dlsyms `main`, calls it. The bundle's auto-generated SwiftPM Runner
//     reads `CommandLine.arguments`, requires `--testing-library swift-testing`
//     to actually invoke `Testing.__swiftPMEntryPoint`, then exits with the
//     test result code.
//   - Exit codes propagate: 0=pass, 1=test failure, 69=no-tests-found,
//     128+N=killed by signal N (e.g., 139=SIGSEGV).

import Foundation
import Darwin

guard let bundlePath = ProcessInfo.processInfo.environment["BUNDLE_PATH"] else {
    FileHandle.standardError.write(Data("runtests: BUNDLE_PATH env var required\n".utf8))
    exit(2)
}

let flags = RTLD_LAZY | RTLD_FIRST
guard let image = dlopen(bundlePath, flags) else {
    let err = dlerror().flatMap { String(validatingCString: $0) } ?? "unknown"
    FileHandle.standardError.write(Data("runtests: dlopen(\(bundlePath)) failed: \(err)\n".utf8))
    exit(3)
}

guard let mainPtr = dlsym(image, "main") else {
    FileHandle.standardError.write(Data("runtests: dlsym(main) returned nil\n".utf8))
    exit(4)
}

typealias MainFn = @convention(c) (CInt, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> CInt
let mainFn = unsafeBitCast(mainPtr, to: MainFn.self)
exit(mainFn(CInt(CommandLine.argc), CommandLine.unsafeArgv))
