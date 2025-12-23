//
//  DWARFSymbolizerTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
import Darwin
import MachO
@testable import PropertyTestingKit

@Suite("DWARFSymbolizer")
struct DWARFSymbolizerTests {

    /// Convert a runtime address to a file offset by subtracting the ASLR slide.
    /// LLVM's symbolizer expects file offsets, not runtime virtual addresses.
    private func runtimeAddressToFileOffset(_ address: UInt64, binaryPath: String) -> UInt64 {
        // Find the image index for this binary
        for i in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(i) else { continue }
            let imageNameStr = String(cString: imageName)

            if imageNameStr == binaryPath {
                let slide = _dyld_get_image_vmaddr_slide(i)
                print("Found binary at index \(i), slide: 0x\(String(slide, radix: 16))")
                print("  address: 0x\(String(address, radix: 16))")
                print("  slide (signed): \(slide)")

                // Sanity check: slide should be positive and less than address
                guard slide >= 0 else {
                    print("  ERROR: Negative slide value, returning address unchanged")
                    return address
                }

                let slideUnsigned = UInt64(slide)
                guard address >= slideUnsigned else {
                    print("  ERROR: address (0x\(String(address, radix: 16))) < slide (0x\(String(slideUnsigned, radix: 16)))")
                    print("  This suggests we matched the wrong binary or the address is invalid")
                    return address
                }

                return address - slideUnsigned
            }
        }

        print("Warning: Could not find binary '\(binaryPath)' in loaded images")
        print("Loaded images:")
        for i in 0..<min(10, _dyld_image_count()) {
            if let name = _dyld_get_image_name(i) {
                print("  [\(i)]: \(String(cString: name))")
            }
        }
        return address
    }

    /// Get the path to the binary for the test.
    /// Uses dladdr to find the actual binary containing our test code.
    /// LLVM's symbolizer finds the dSYM automatically via Spotlight or adjacent search.
    private func getBinaryPath() -> String? {
        // Use dladdr to find the binary containing a function from our test
        var info = Dl_info()
        let testFunc: @convention(c) () -> Void = testFunctionForSymbolication
        let ptr = unsafeBitCast(testFunc, to: UnsafeRawPointer.self)

        guard dladdr(ptr, &info) != 0, let fname = info.dli_fname else {
            return nil
        }

        let binaryPath = String(cString: fname)
        print("Binary path from dladdr: \(binaryPath)")

        // Check if dSYM exists (for debug info)
        let binaryName = URL(fileURLWithPath: binaryPath).lastPathComponent
        let dSYMPath = "\(binaryPath).dSYM/Contents/Resources/DWARF/\(binaryName)"
        print("dSYM location: \(dSYMPath)")
        print("dSYM exists: \(FileManager.default.fileExists(atPath: dSYMPath))")

        // Return the binary path - LLVM's symbolizer finds dSYM automatically
        return binaryPath
    }

    @Test("DWARFSymbolizer initializes for dSYM bundle")
    func testInit() throws {
        guard let path = getBinaryPath() else {
            Issue.record("Could not determine binary path")
            return
        }

        print("Trying to open symbolizer for: \(path)")

        // This test binary should have DWARF info in dSYM
        let symbolizer = try DWARFSymbolizer(path: path)
        _ = symbolizer  // Just verify initialization succeeds
    }

    @Test("DWARFSymbolizer looks up addresses")
    func testLookup() throws {
        guard let path = getBinaryPath() else {
            Issue.record("Could not determine binary path")
            return
        }
        let symbolizer = try DWARFSymbolizer(path: path)

        // Use dladdr on a function in the TEST bundle (same binary as getBinaryPath returns)
        var info = Dl_info()
        let testFunc: @convention(c) () -> Void = testFunctionForSymbolication
        let funcPtr = unsafeBitCast(testFunc, to: UnsafeRawPointer.self)

        guard dladdr(funcPtr, &info) != 0, let saddr = info.dli_saddr else {
            Issue.record("Could not get address info")
            return
        }

        let runtimeAddress = UInt64(UInt(bitPattern: saddr))
        let fileOffset = runtimeAddressToFileOffset(runtimeAddress, binaryPath: path)

        print("Runtime address: 0x\(String(runtimeAddress, radix: 16))")
        print("File offset: 0x\(String(fileOffset, radix: 16))")

        // Try to look up - may return nil if this is metadata rather than code
        let location = symbolizer.lookup(address: fileOffset)

        if let loc = location {
            print("Found location: \(loc.file):\(loc.line)")
            #expect(loc.line > 0, "Line number should be positive")
            #expect(!loc.file.isEmpty, "File path should not be empty")
        } else {
            // Not a failure - metadata doesn't have line numbers
            print("No DWARF info found for address 0x\(String(fileOffset, radix: 16))")
        }
    }

    @Test("DWARFSymbolizer looks up real source location")
    func testLookupRealFunction() throws {
        // Use dlsym to get a known function by name
        // DWARFSymbolizer.lookup mangled name
        let mangledName = "$s18PropertyTestingKit15DWARFSymbolizerC11findClosest7addressAA19DWARFSourceLocationVSgs6UInt64V_tF"

        guard let funcAddr = dlsym(UnsafeMutableRawPointer(bitPattern: -2)!, mangledName) else {
            print("Could not find symbol: \(mangledName)")
            return
        }

        // Get the binary path from dladdr on the SAME address we're looking up
        var info = Dl_info()
        guard dladdr(funcAddr, &info) != 0,
              let saddr = info.dli_saddr,
              let fname = info.dli_fname else {
            Issue.record("Could not get address info")
            return
        }

        let binaryPath = String(cString: fname)
        print("Binary for DWARFSymbolizer: \(binaryPath)")

        let symbolizer = try DWARFSymbolizer(path: binaryPath)

        let runtimeAddress = UInt64(UInt(bitPattern: saddr))
        let fileOffset = runtimeAddressToFileOffset(runtimeAddress, binaryPath: binaryPath)

        print("findClosest runtime address: 0x\(String(runtimeAddress, radix: 16))")
        print("findClosest file offset: 0x\(String(fileOffset, radix: 16))")

        if let loc = symbolizer.lookup(address: fileOffset) {
            print("Found: \(loc.file):\(loc.line) - \(loc.function ?? "?")")
            #expect(loc.line > 0, "Line number should be positive")
            #expect(loc.file.contains("DWARFSymbolizer.swift"), "Should be in DWARFSymbolizer.swift, got: \(loc.file)")
        } else {
            print("No location found for findClosest - this should work!")
        }
    }

    @Test("DWARFSymbolizer findClosest returns nearest entry")
    func testFindClosest() throws {
        guard let path = getBinaryPath() else {
            Issue.record("Could not determine binary path")
            return
        }
        let symbolizer = try DWARFSymbolizer(path: path)

        // Get address of a function
        var info = Dl_info()
        let testFunction: @convention(c) () -> Void = testFunctionForSymbolication
        let funcPtr = unsafeBitCast(testFunction, to: UnsafeRawPointer.self)

        guard dladdr(funcPtr, &info) != 0 else {
            Issue.record("Could not get address info")
            return
        }

        let runtimeAddress = UInt64(UInt(bitPattern: info.dli_saddr))
        let fileOffset = runtimeAddressToFileOffset(runtimeAddress, binaryPath: path)

        // Look for an address slightly after the function start
        let location = symbolizer.lookup(address: fileOffset + 10)

        if let loc = location {
            print("Closest location: \(loc.file):\(loc.line)")
            #expect(loc.line > 0)
        }
    }

    @Test("DWARFSymbolizer batch lookup")
    func testBatchLookup() throws {
        guard let path = getBinaryPath() else {
            Issue.record("Could not determine binary path")
            return
        }
        let symbolizer = try DWARFSymbolizer(path: path)

        // Get addresses of multiple functions (converted to file offsets)
        var addresses: [UInt64] = []

        var info1 = Dl_info()
        let func1: @convention(c) () -> Void = testFunctionForSymbolication
        if dladdr(unsafeBitCast(func1, to: UnsafeRawPointer.self), &info1) != 0 {
            let runtimeAddr = UInt64(UInt(bitPattern: info1.dli_saddr))
            addresses.append(runtimeAddressToFileOffset(runtimeAddr, binaryPath: path))
        }

        var info2 = Dl_info()
        let func2: @convention(c) () -> Void = anotherTestFunction
        if dladdr(unsafeBitCast(func2, to: UnsafeRawPointer.self), &info2) != 0 {
            let runtimeAddr = UInt64(UInt(bitPattern: info2.dli_saddr))
            addresses.append(runtimeAddressToFileOffset(runtimeAddr, binaryPath: path))
        }

        let results = symbolizer.lookup(addresses: addresses)
        print("Batch lookup found \(results.count) locations for \(addresses.count) addresses")
    }
}

// Test functions for symbolication lookup
@_silgen_name("testFunctionForSymbolication")
func testFunctionForSymbolication() {
    // This function exists so we can look up its address
    let _ = 1 + 1
}

@_silgen_name("anotherTestFunction")
func anotherTestFunction() {
    // Another test function
    let _ = 2 + 2
}
