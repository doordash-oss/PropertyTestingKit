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

//
//  CLLVMSymbolizer.h
//  PropertyTestingKit
//
//  C wrapper for LLVM's LLVMSymbolizer for address-to-line lookup.
//

#ifndef CLLVM_SYMBOLIZER_H
#define CLLVM_SYMBOLIZER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to an LLVM symbolizer instance.
typedef struct LLVMSymbolizerContext* LLVMSymbolizerRef;

/// Result of a symbolization lookup.
typedef struct {
    /// Source file path (owned, must be freed with llvm_symbolizer_free_string).
    char* file;
    /// Function name (owned, must be freed with llvm_symbolizer_free_string).
    char* function;
    /// Line number (0 if unknown).
    uint32_t line;
    /// Column number (0 if unknown).
    uint32_t column;
    /// Whether the lookup succeeded.
    bool success;
} LLVMSymbolizeResult;

/// Create a new symbolizer for the given module path.
/// @param module_path Path to the binary or dSYM file.
/// @return Symbolizer handle, or NULL on failure.
LLVMSymbolizerRef llvm_symbolizer_create(const char* module_path);

/// Destroy a symbolizer and free its resources.
void llvm_symbolizer_destroy(LLVMSymbolizerRef symbolizer);

/// Look up source location for an address.
/// @param symbolizer The symbolizer handle.
/// @param address The address to look up.
/// @return Result struct with file, function, line, column.
LLVMSymbolizeResult llvm_symbolizer_lookup(LLVMSymbolizerRef symbolizer, uint64_t address);

/// Look up multiple addresses at once.
/// @param symbolizer The symbolizer handle.
/// @param addresses Array of addresses.
/// @param count Number of addresses.
/// @param results Output array (must be pre-allocated with `count` elements).
void llvm_symbolizer_lookup_batch(
    LLVMSymbolizerRef symbolizer,
    const uint64_t* addresses,
    size_t count,
    LLVMSymbolizeResult* results
);

/// Free a string returned by the symbolizer.
void llvm_symbolizer_free_string(char* str);

/// Free the strings in a result struct.
void llvm_symbolizer_free_result(LLVMSymbolizeResult* result);

/// Get the last error message (if any).
/// @return Error message or NULL. Do not free.
const char* llvm_symbolizer_get_error(void);

#ifdef __cplusplus
}
#endif

#endif // CLLVM_SYMBOLIZER_H
