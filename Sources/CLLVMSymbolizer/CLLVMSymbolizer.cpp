//
//  CLLVMSymbolizer.cpp
//  PropertyTestingKit
//
//  C wrapper implementation for LLVM's LLVMSymbolizer.
//

#include "CLLVMSymbolizer.h"

#include <llvm/DebugInfo/Symbolize/Symbolize.h>
#include <llvm/Object/ObjectFile.h>
#include <llvm/Support/Error.h>

#include <string>
#include <mutex>
#include <cstring>
#include <new>

using namespace llvm;
using namespace llvm::symbolize;
using namespace llvm::object;

// Thread-local error message storage
static thread_local std::string g_last_error;

// Global mutex to serialize all LLVM symbolizer operations
// LLVM's LLVMSymbolizer may have internal state that isn't fully thread-safe
static std::mutex g_global_symbolizer_mutex;

struct LLVMSymbolizerContext {
    std::unique_ptr<LLVMSymbolizer> symbolizer;
    std::string module_path;
    std::mutex mutex;

    LLVMSymbolizerContext(const char* path) : module_path(path) {
        LLVMSymbolizer::Options opts;
        opts.PrintFunctions = DILineInfoSpecifier::FunctionNameKind::LinkageName;
        opts.UseSymbolTable = true;
        opts.Demangle = true;
        symbolizer = std::make_unique<LLVMSymbolizer>(opts);
    }
};

extern "C" {

LLVMSymbolizerRef llvm_symbolizer_create(const char* module_path) {
    if (!module_path) {
        g_last_error = "module_path is NULL";
        return nullptr;
    }

    // Serialize symbolizer creation
    std::lock_guard<std::mutex> global_lock(g_global_symbolizer_mutex);

    auto ctx = new (std::nothrow) LLVMSymbolizerContext(module_path);
    if (!ctx) {
        g_last_error = "Failed to allocate symbolizer context";
        return nullptr;
    }
    return ctx;
}

void llvm_symbolizer_destroy(LLVMSymbolizerRef symbolizer) {
    if (symbolizer) {
        // Serialize symbolizer destruction
        std::lock_guard<std::mutex> global_lock(g_global_symbolizer_mutex);
        delete symbolizer;
    }
}

LLVMSymbolizeResult llvm_symbolizer_lookup(LLVMSymbolizerRef symbolizer, uint64_t address) {
    LLVMSymbolizeResult result = {};
    result.success = false;

    if (!symbolizer) {
        g_last_error = "symbolizer is NULL";
        return result;
    }

    // Use global mutex to serialize all LLVM operations
    // LLVM's internal state may not be fully thread-safe
    std::lock_guard<std::mutex> global_lock(g_global_symbolizer_mutex);
    std::lock_guard<std::mutex> lock(symbolizer->mutex);

    // Create sectioned address (section index 0 for .text-like sections)
    SectionedAddress addr;
    addr.Address = address;
    addr.SectionIndex = SectionedAddress::UndefSection;

    Expected<DILineInfo> info_or_err =
        symbolizer->symbolizer->symbolizeCode(symbolizer->module_path, addr);

    if (!info_or_err) {
        g_last_error = toString(info_or_err.takeError());
        return result;
    }

    DILineInfo& info = *info_or_err;

    // Check if we got valid info (not the default "invalid" values)
    if (info.FileName != DILineInfo::BadString && info.Line != 0) {
        result.file = strdup(info.FileName.c_str());
        result.function = strdup(info.FunctionName.c_str());
        result.line = info.Line;
        result.column = info.Column;
        result.success = true;
    }

    return result;
}

void llvm_symbolizer_lookup_batch(
    LLVMSymbolizerRef symbolizer,
    const uint64_t* addresses,
    size_t count,
    LLVMSymbolizeResult* results
) {
    if (!symbolizer || !addresses || !results) {
        g_last_error = "NULL argument to lookup_batch";
        return;
    }

    for (size_t i = 0; i < count; ++i) {
        results[i] = llvm_symbolizer_lookup(symbolizer, addresses[i]);
    }
}

void llvm_symbolizer_free_string(char* str) {
    if (str) {
        free(str);
    }
}

void llvm_symbolizer_free_result(LLVMSymbolizeResult* result) {
    if (result) {
        llvm_symbolizer_free_string(result->file);
        llvm_symbolizer_free_string(result->function);
        result->file = nullptr;
        result->function = nullptr;
    }
}

const char* llvm_symbolizer_get_error(void) {
    return g_last_error.empty() ? nullptr : g_last_error.c_str();
}

} // extern "C"
