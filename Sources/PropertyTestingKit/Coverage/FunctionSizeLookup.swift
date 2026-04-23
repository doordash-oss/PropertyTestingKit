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

// Note: This is only currently used for coverage gap detection.

/// Helper for looking up function sizes from the Mach-O symbol table.
/// Parses the symbol table once at init, then provides O(log n) lookups.
struct FunctionSizeLookup: Sendable {
    /// Sorted array of (address, size) for binary search
    private let functionBounds: [(address: UInt, size: UInt)]
    private let slide: Int

    /// Initialize and parse the symbol table.
    init() {
        // Find the test binary
        var targetImageIndex: UInt32 = 0
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            let path = String(cString: name)
            if path.contains(".xctest/") {
                targetImageIndex = i
                break
            }
        }

        guard let headerRaw = _dyld_get_image_header(targetImageIndex) else {
            self.functionBounds = []
            self.slide = 0
            return
        }
        self.slide = _dyld_get_image_vmaddr_slide(targetImageIndex)

        // Cast to 64-bit header (we're always on 64-bit Apple Silicon)
        let header = UnsafeRawPointer(headerRaw).assumingMemoryBound(to: mach_header_64.self)

        // Parse symbol table from Mach-O header
        var symbols: [(address: UInt, name: String)] = []

        // Iterate load commands to find LC_SYMTAB
        var commandPtr = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = commandPtr.assumingMemoryBound(to: load_command.self).pointee

            if command.cmd == LC_SYMTAB {
                let symtabCmd = commandPtr.assumingMemoryBound(to: symtab_command.self).pointee

                // Get pointers to symbol table and string table
                let linkeditBase = Self.findLinkeditBase(header: header, slide: slide)
                guard linkeditBase != nil else { break }

                let symtabPtr = linkeditBase!.advanced(by: Int(symtabCmd.symoff))
                    .assumingMemoryBound(to: nlist_64.self)
                let strtabPtr = linkeditBase!.advanced(by: Int(symtabCmd.stroff))
                    .assumingMemoryBound(to: CChar.self)

                // Extract function symbols (type 0x0f = N_SECT, external or local)
                for i in 0..<Int(symtabCmd.nsyms) {
                    let nlist = symtabPtr[i]
                    let type = nlist.n_type & UInt8(N_TYPE)

                    // Only include defined symbols in a section (functions/data)
                    if type == UInt8(N_SECT) {
                        let nameOffset = Int(nlist.n_un.n_strx)
                        let name = String(cString: strtabPtr.advanced(by: nameOffset))

                        // Filter to likely function symbols (not empty, not metadata)
                        if !name.isEmpty && !name.hasPrefix("_$s") == false {
                            let address = UInt(nlist.n_value) + UInt(bitPattern: slide)
                            symbols.append((address: address, name: name))
                        }
                    }
                }
                break
            }

            commandPtr = commandPtr.advanced(by: Int(command.cmdsize))
        }

        // Sort by address
        symbols.sort { $0.address < $1.address }

        // Compute sizes as gaps between adjacent symbols
        var bounds: [(address: UInt, size: UInt)] = []
        bounds.reserveCapacity(symbols.count)
        for i in 0..<symbols.count {
            let address = symbols[i].address
            let size: UInt
            if i + 1 < symbols.count {
                size = symbols[i + 1].address - address
            } else {
                size = 4096  // Default for last symbol
            }
            bounds.append((address: address, size: size))
        }
        self.functionBounds = bounds

#if DEBUG
        print("[FunctionSizeLookup] Parsed \(functionBounds.count) symbols from symbol table")
#endif
    }

    /// Find the base address where linkedit segment is mapped.
    /// For a loaded binary, the linkedit data is at: slide + vmaddr
    private static func findLinkeditBase(header: UnsafePointer<mach_header_64>, slide: Int) -> UnsafeRawPointer? {
        var commandPtr = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var linkeditVMAddr: UInt64 = 0
        var linkeditFileOff: UInt64 = 0

        for _ in 0..<header.pointee.ncmds {
            let command = commandPtr.assumingMemoryBound(to: load_command.self).pointee

            if command.cmd == LC_SEGMENT_64 {
                let segment = commandPtr.assumingMemoryBound(to: segment_command_64.self).pointee
                let segname = withUnsafeBytes(of: segment.segname) { ptr -> String in
                    let bytes = ptr.bindMemory(to: CChar.self)
                    return String(cString: bytes.baseAddress!)
                }
                if segname == "__LINKEDIT" {
                    linkeditVMAddr = segment.vmaddr
                    linkeditFileOff = segment.fileoff
                }
            }

            commandPtr = commandPtr.advanced(by: Int(command.cmdsize))
        }

        guard linkeditVMAddr > 0 else { return nil }

        // The linkedit base for offset lookups is: slide + linkedit_vmaddr - linkedit_fileoff
        let slideU64 = UInt64(bitPattern: Int64(slide))
        let linkeditBase = slideU64 + linkeditVMAddr - linkeditFileOff
        return UnsafeRawPointer(bitPattern: UInt(linkeditBase))
    }

    /// Look up the size of a function given its start address.
    /// Returns nil if the address is not found.
    func getSize(forFunctionAt address: UInt) -> UInt? {
        // Binary search for the address
        var low = 0
        var high = functionBounds.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let entry = functionBounds[mid]

            if entry.address == address {
                return entry.size
            } else if entry.address < address {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return nil
    }

    /// Get sizes for multiple function addresses at once.
    func getSizes(forFunctionsAt addresses: [UInt]) -> [UInt: UInt] {
        var result: [UInt: UInt] = [:]
        result.reserveCapacity(addresses.count)

        for address in addresses {
            if let size = getSize(forFunctionAt: address) {
                result[address] = size
            }
        }

        return result
    }

    /// Check if the lookup table is available.
    var isAvailable: Bool {
        return !functionBounds.isEmpty
    }
}
