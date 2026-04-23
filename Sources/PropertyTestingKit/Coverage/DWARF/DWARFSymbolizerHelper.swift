// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SanCovHooks
import MachO

/// Helper for DWARF-based line number resolution.
/// Lazily initializes the symbolizer on first use and handles
/// runtime-specific concerns like ASLR slide calculation.
actor DWARFSymbolizerHelper {
    private var _symbolizer: DWARFSymbolizer?
    private var _binaryPath: String?
    private var _slide: Int = 0
    private var _initialized = false

    /// Get or create the shared symbolizer for the current process.
    var shared: DWARFSymbolizer? {
        if !_initialized {
            _initialized = true
            initializeSymbolizer()
        }
        return _symbolizer
    }

    /// Get the ASLR slide for converting runtime addresses to file offsets.
    var slide: Int {
        if !_initialized {
            _initialized = true
            initializeSymbolizer()
        }
        return _slide
    }

    private func initializeSymbolizer() {
        // Find the main executable path
        guard let path = findMainBinaryPath() else {
#if DEBUG
            print("[DWARFSymbolizer] Could not find main binary path")
#endif
            return
        }
        _binaryPath = path

        // Find the slide for this binary
        _slide = findSlide(for: path)

#if DEBUG
        print("[DWARFSymbolizer] Binary: \(path)")
        print("[DWARFSymbolizer] Slide: 0x\(String(_slide, radix: 16))")
#endif

        // Create symbolizer
        do {
            _symbolizer = try DWARFSymbolizer(path: path)
#if DEBUG
            print("[DWARFSymbolizer] Initialized successfully")
#endif
        } catch {
#if DEBUG
            print("[DWARFSymbolizer] Failed to initialize: \(error)")
#endif
            // Symbolizer unavailable - that's okay, we fall back to dladdr
        }
    }

    private func findMainBinaryPath() -> String? {
        // Find the test binary by looking for .xctest bundle
        // The first image is often swiftpm-testing-helper, not the actual tests
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            let path = String(cString: name)

            // Look for .xctest bundle (Swift PM test binary)
            if path.contains(".xctest/") {
                return path
            }
        }

        // Fallback: first image
        guard _dyld_image_count() > 0,
              let name = _dyld_get_image_name(0) else {
            return nil
        }
        return String(cString: name)
    }

    private func findSlide(for path: String) -> Int {
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            if String(cString: name) == path {
                return _dyld_get_image_vmaddr_slide(i)
            }
        }
        return 0
    }

    /// Convert a runtime PC address to a file offset.
    /// Uses overflow-safe arithmetic since TSan can change memory layout
    /// in ways that make address calculations overflow.
    func runtimeToFileOffset(_ pc: UInt) -> UInt64 {
        let pcValue = UInt64(pc)
        let slideValue = UInt64(bitPattern: Int64(slide))
        // Use wrapping subtraction to avoid overflow trap
        return pcValue &- slideValue
    }

    /// Look up DWARF info for a PC address.
    func lookup(pc: UInt) async -> DWARFSourceLocation? {
        guard let symbolizer = shared else {
            return nil
        }
        let fileOffset = runtimeToFileOffset(pc)
        return symbolizer.lookup(address: fileOffset)
    }

    /// Batch look up DWARF info for multiple PC addresses.
    func lookupBatch(pcs: [UInt]) async -> [UInt: DWARFSourceLocation] {
        guard let symbolizer = shared else {
            return [:]
        }

        // Convert runtime PCs to file offsets
        let addresses = pcs.map { runtimeToFileOffset($0) }

        // Batch lookup
        let results = symbolizer.lookup(addresses: addresses)

        // Map back to runtime PCs
        var pcResults: [UInt: DWARFSourceLocation] = [:]
        pcResults.reserveCapacity(results.count)
        for (i, pc) in pcs.enumerated() {
            let fileOffset = addresses[i]
            if let location = results[fileOffset] {
                pcResults[pc] = location
            }
        }
        return pcResults
    }

    /// Check if the symbolizer is available.
    var isAvailable: Bool {
        shared != nil
    }
}
