//
//  LLVMCoverageInterop.cpp
//  PropertyTestingKit
//
//  Implementation of LLVM coverage wrapper.
//

#include "include/LLVMCoverageInterop.hpp"

#include <llvm/ProfileData/Coverage/CoverageMapping.h>
#include <llvm/ProfileData/Coverage/CoverageMappingReader.h>
#include <llvm/ProfileData/InstrProfReader.h>
#include <llvm/ProfileData/InstrProf.h>
#include <llvm/Support/VirtualFileSystem.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Object/ObjectFile.h>

#include <set>
#include <unordered_map>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

// Profile runtime symbols (weak to allow graceful failure if not linked)
extern "C" {
    extern const void* __llvm_profile_begin_data(void) __attribute__((weak));
    extern const void* __llvm_profile_end_data(void) __attribute__((weak));
}

using namespace llvm;
using namespace llvm::coverage;

namespace ptk {

// Private implementation
struct CoverageReader::Impl {
    std::unique_ptr<CoverageMapping> coverage;

    Impl(std::unique_ptr<CoverageMapping> cov) : coverage(std::move(cov)) {}
};

CoverageReader::CoverageReader() : pImpl(nullptr) {}

CoverageReader::~CoverageReader() = default;

CoverageReader* CoverageReader::load(
    const std::string& objectPath,
    const std::string& profilePath,
    CoverageError& outError
) {
    // Use the real filesystem
    auto FS = vfs::getRealFileSystem();

    // Load coverage mapping
    auto coverageOrErr = CoverageMapping::load(
        ArrayRef<StringRef>(StringRef(objectPath)),
        StringRef(profilePath),
        *FS
    );

    if (auto err = coverageOrErr.takeError()) {
        std::string errMsg;
        raw_string_ostream os(errMsg);
        os << err;
        outError = CoverageError::make(os.str());
        return nullptr;
    }

    auto reader = new CoverageReader();
    reader->pImpl = std::make_unique<Impl>(std::move(*coverageOrErr));
    outError = CoverageError::none();
    return reader;
}

void CoverageReader::destroy(CoverageReader* reader) {
    delete reader;
}

std::vector<std::string> CoverageReader::getSourceFiles() const {
    std::vector<std::string> files;
    if (!pImpl || !pImpl->coverage) return files;

    auto uniqueFiles = pImpl->coverage->getUniqueSourceFiles();
    files.reserve(uniqueFiles.size());
    for (const auto& f : uniqueFiles) {
        files.push_back(f.str());
    }
    return files;
}

FileCoverage CoverageReader::getFileCoverage(const std::string& filename) const {
    FileCoverage result;
    result.filename = filename;
    result.coveredLines = 0;
    result.totalLines = 0;

    if (!pImpl || !pImpl->coverage) return result;

    auto coverageData = pImpl->coverage->getCoverageForFile(filename);

    // Iterate over lines
    for (const auto& segment : coverageData) {
        // Process segments to build line coverage
        // This is simplified - real implementation would properly handle segments
    }

    // Use LineCoverageIterator for more accurate line-by-line coverage
    auto lineCovIt = LineCoverageIterator(coverageData);
    auto lineCovEnd = lineCovIt.getEnd();

    for (; lineCovIt != lineCovEnd; ++lineCovIt) {
        LineCoverage lc;
        lc.line = lineCovIt->getLine();
        lc.executionCount = lineCovIt->getExecutionCount();
        lc.isMapped = lineCovIt->isMapped();
        lc.hasMultipleRegions = lineCovIt->hasMultipleRegions();

        result.lines.push_back(lc);

        if (lc.isMapped) {
            result.totalLines++;
            if (lc.executionCount > 0) {
                result.coveredLines++;
            }
        }
    }

    return result;
}

CoverageSummary CoverageReader::getSummary() const {
    CoverageSummary summary{};

    if (!pImpl || !pImpl->coverage) return summary;

    // Iterate over all functions to build summary
    for (const auto& func : pImpl->coverage->getCoveredFunctions()) {
        summary.totalFunctions++;
        bool functionCovered = false;

        for (const auto& region : func.CountedRegions) {
            summary.totalRegions++;
            if (region.ExecutionCount > 0) {
                summary.coveredRegions++;
                functionCovered = true;
            }
        }

        if (functionCovered) {
            summary.coveredFunctions++;
        }
    }

    // Get line coverage from all files
    for (const auto& filename : pImpl->coverage->getUniqueSourceFiles()) {
        auto coverageData = pImpl->coverage->getCoverageForFile(filename);
        auto lineCovIt = LineCoverageIterator(coverageData);
        auto lineCovEnd = lineCovIt.getEnd();

        for (; lineCovIt != lineCovEnd; ++lineCovIt) {
            if (lineCovIt->isMapped()) {
                summary.totalLines++;
                if (lineCovIt->getExecutionCount() > 0) {
                    summary.coveredLines++;
                }
            }
        }
    }

    return summary;
}

uint64_t CoverageReader::getLineExecutionCount(
    const std::string& filename,
    uint32_t line
) const {
    if (!pImpl || !pImpl->coverage) return 0;

    auto coverageData = pImpl->coverage->getCoverageForFile(filename);
    auto lineCovIt = LineCoverageIterator(coverageData);
    auto lineCovEnd = lineCovIt.getEnd();

    for (; lineCovIt != lineCovEnd; ++lineCovIt) {
        if (lineCovIt->getLine() == line && lineCovIt->isMapped()) {
            return lineCovIt->getExecutionCount();
        }
    }

    return 0;
}

bool CoverageReader::isLineCovered(
    const std::string& filename,
    uint32_t line
) const {
    return getLineExecutionCount(filename, line) > 0;
}

// MARK: - InMemoryCoverageReader Implementation

/// Get the path to the current executable.
/// On macOS with Swift Testing, the main executable might be a helper process,
/// so we need to find our test binary by looking for loaded images with coverage sections.
static std::string getCurrentExecutablePath() {
#if defined(__APPLE__)
    // First, try the main executable
    uint32_t bufsize = 0;
    _NSGetExecutablePath(nullptr, &bufsize);
    std::vector<char> buf(bufsize);
    if (_NSGetExecutablePath(buf.data(), &bufsize) == 0) {
        char resolved[PATH_MAX];
        if (realpath(buf.data(), resolved)) {
            return std::string(resolved);
        }
        return std::string(buf.data());
    }
#endif
    return "";
}

/// Find a loaded image that has coverage mapping data.
/// This is needed for Swift Testing which runs tests via a helper process.
static std::vector<std::string> findLoadedImagesWithCoverage() {
    std::vector<std::string> images;
#if defined(__APPLE__)
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        if (!name) continue;

        std::string path(name);
        // Skip system libraries and frameworks
        if (path.find("/usr/lib/") == 0 ||
            path.find("/System/") == 0 ||
            path.find("/Library/Developer/") == 0 ||
            path.find("/Applications/Xcode") == 0) {
            continue;
        }

        images.push_back(path);
    }
#endif
    return images;
}

/// Parsed coverage mapping record stored for later resolution.
struct ParsedFunctionRecord {
    std::string functionName;
    uint64_t functionHash;
    uint64_t nameRef;  // MD5 hash of function name for matching with runtime data
    std::vector<std::string> filenames;
    std::vector<CounterExpression> expressions;
    std::vector<CounterMappingRegion> regions;
};

struct InMemoryCoverageReader::Impl {
    std::vector<ParsedFunctionRecord> functions;
    std::vector<std::string> sourceFiles;

    /// Parse coverage mapping from a binary file.
    static std::unique_ptr<Impl> loadFromFile(
        const std::string& path,
        CoverageError& outError
    ) {
        // Read the binary file
        auto bufOrErr = MemoryBuffer::getFile(path);
        if (!bufOrErr) {
            outError = CoverageError::make(
                "Failed to read binary: " + bufOrErr.getError().message()
            );
            return nullptr;
        }

        auto impl = std::make_unique<Impl>();

        // Create coverage readers from the object file
        SmallVector<std::unique_ptr<MemoryBuffer>, 4> objectFileBuffers;
        auto readersOrErr = BinaryCoverageReader::create(
            bufOrErr.get()->getMemBufferRef(),
            "", // arch (empty = host arch)
            objectFileBuffers
        );

        if (auto err = readersOrErr.takeError()) {
            std::string errMsg;
            raw_string_ostream os(errMsg);
            os << err;
            outError = CoverageError::make("Failed to parse coverage: " + os.str());
            return nullptr;
        }

        // Collect unique source files
        std::set<std::string> uniqueFiles;

        // Parse all function records
        for (auto& reader : *readersOrErr) {
            CoverageMappingRecord record;
            while (true) {
                auto err = reader->readNextRecord(record);
                if (err) {
                    // End of records or error
                    consumeError(std::move(err));
                    break;
                }

                ParsedFunctionRecord func;
                func.functionName = record.FunctionName.str();
                func.functionHash = record.FunctionHash;
                // Compute MD5 hash of function name for matching with runtime data
                func.nameRef = IndexedInstrProf::ComputeHash(record.FunctionName);

                // Debug: Print first few function name hashes
                static int debugCount = 0;
                if (debugCount < 3) {
                    fprintf(stderr, "[DEBUG] Parsed function: %s, nameRef: 0x%llx, funcHash: 0x%llx\n",
                            func.functionName.c_str(),
                            (unsigned long long)func.nameRef,
                            (unsigned long long)func.functionHash);
                    debugCount++;
                }

                // Copy filenames
                for (const auto& f : record.Filenames) {
                    func.filenames.push_back(f.str());
                    uniqueFiles.insert(f.str());
                }

                // Copy expressions
                for (const auto& e : record.Expressions) {
                    func.expressions.push_back(e);
                }

                // Copy regions
                for (const auto& r : record.MappingRegions) {
                    func.regions.push_back(r);
                }

                impl->functions.push_back(std::move(func));
            }
        }

        impl->sourceFiles.assign(uniqueFiles.begin(), uniqueFiles.end());
        outError = CoverageError::none();
        return impl;
    }

    /// Build a map from function hash to profile data record.
    /// This allows us to find the correct counters for each function.
    static std::unordered_map<uint64_t, std::pair<const uint64_t*, uint32_t>>
    buildFunctionCounterMap(const uint64_t* globalCounterBegin, size_t globalCounterCount) {
        std::unordered_map<uint64_t, std::pair<const uint64_t*, uint32_t>> map;

        // Safely check if profile runtime functions are available
        if (__llvm_profile_begin_data == nullptr || __llvm_profile_end_data == nullptr) {
            return map;
        }

        const void* beginPtr = __llvm_profile_begin_data();
        const void* endPtr = __llvm_profile_end_data();

        // Debug: Print global counter range
        const uint64_t* globalCounterEnd = globalCounterBegin + globalCounterCount;
        fprintf(stderr, "[DEBUG] Global counter range: %p - %p (%zu counters)\n",
                (void*)globalCounterBegin, (void*)globalCounterEnd, globalCounterCount);

        if (beginPtr == nullptr || endPtr == nullptr || beginPtr >= endPtr) {
            return map;
        }

        // Profile data structure (matches LLVM's __llvm_profile_data layout)
        // IPVK_Last = 2 in current LLVM, so NumValueSites has 3 elements
        struct ProfileData {
            uint64_t NameRef;           // 8 bytes
            uint64_t FuncHash;          // 8 bytes
            int64_t CounterDelta;       // 8 bytes - relative offset, not pointer!
            int64_t BitmapDelta;        // 8 bytes - relative offset
            void *FunctionPointer;      // 8 bytes (pointer)
            void *Values;               // 8 bytes (pointer)
            uint32_t NumCounters;       // 4 bytes
            uint16_t NumValueSites[3];  // 6 bytes (IPVK_Last+1 = 3)
            uint32_t NumBitmapBytes;    // 4 bytes
            // Total: 62 bytes, padded to 64 bytes
        };

        static_assert(sizeof(ProfileData) == 64, "ProfileData size mismatch");

        auto dataBegin = reinterpret_cast<const ProfileData*>(beginPtr);
        auto dataEnd = reinterpret_cast<const ProfileData*>(endPtr);

        size_t totalRecords = 0;
        // Interesting nameRef values to look for (from coverage mapping)
        // We'll compare these with runtime values
        uint64_t writeNameRef = IndexedInstrProf::ComputeHash("$s23PropertyTestingKitTests12MockDatabaseC5write3key5valueySS_SStF");
        uint64_t writeWithPathNameRef = IndexedInstrProf::ComputeHash("/Users/alex.reilly/Documents/Swift/PropertyTestingKit/Tests/PropertyTestingKitTests/MockDatabase.swift:$s23PropertyTestingKitTests12MockDatabaseC5write3key5valueySS_SStF");
        uint64_t writeCountInitNameRef = IndexedInstrProf::ComputeHash("/Users/alex.reilly/Documents/Swift/PropertyTestingKit/Tests/PropertyTestingKitTests/MockDatabase.swift:$s23PropertyTestingKitTests12MockDatabaseC10writeCountSivpfi");
        uint64_t writeCountInitNoPathNameRef = IndexedInstrProf::ComputeHash("$s23PropertyTestingKitTests12MockDatabaseC10writeCountSivpfi");

        fprintf(stderr, "[DEBUG] Expected nameRef for write() (no path): 0x%llx\n", (unsigned long long)writeNameRef);
        fprintf(stderr, "[DEBUG] Expected nameRef for write() (with path): 0x%llx\n", (unsigned long long)writeWithPathNameRef);
        fprintf(stderr, "[DEBUG] Expected nameRef for writeCountInit (with path): 0x%llx\n", (unsigned long long)writeCountInitNameRef);
        fprintf(stderr, "[DEBUG] Expected nameRef for writeCountInit (no path): 0x%llx\n", (unsigned long long)writeCountInitNoPathNameRef);

        for (auto data = dataBegin; data < dataEnd; ++data) {
            if (data->NumCounters > 0 && data->NumCounters < 10000) {
                // CounterDelta is a relative offset from &CounterDelta to the counters
                const uint64_t* counters = reinterpret_cast<const uint64_t*>(
                    reinterpret_cast<const char*>(&data->CounterDelta) + data->CounterDelta
                );
                // Use NameRef (MD5 of function name) as key since FuncHash is often 0
                map[data->NameRef] = {counters, data->NumCounters};
                totalRecords++;

                // Check if this is one of our interesting functions
                if (data->NameRef == writeNameRef || data->NameRef == writeWithPathNameRef) {
                    bool inGlobalRange = (counters >= globalCounterBegin && counters < globalCounterEnd);
                    bool withPath = (data->NameRef == writeWithPathNameRef);
                    fprintf(stderr, "[DEBUG] Runtime write() %s found: nameRef=0x%llx, counters=%p, counters[0]=%llu, inGlobalRange=%s\n",
                            withPath ? "(with path)" : "(no path)",
                            (unsigned long long)data->NameRef,
                            (void*)counters,
                            (unsigned long long)counters[0],
                            inGlobalRange ? "YES" : "NO");
                }
                if (data->NameRef == writeCountInitNameRef || data->NameRef == writeCountInitNoPathNameRef) {
                    bool inGlobalRange = (counters >= globalCounterBegin && counters < globalCounterEnd);
                    fprintf(stderr, "[DEBUG] Runtime writeCountInit found: nameRef=0x%llx, counters=%p, counters[0]=%llu, inGlobalRange=%s\n",
                            (unsigned long long)data->NameRef,
                            (void*)counters,
                            (unsigned long long)counters[0],
                            inGlobalRange ? "YES" : "NO");
                }
            }
        }
        fprintf(stderr, "[DEBUG] Total runtime profile data records: %zu\n", totalRecords);

        return map;
    }

    /// Resolve coverage using in-memory counter values from profile data records.
    InMemoryCoverageData resolveCoverage(
        const uint64_t* globalCounters,
        size_t count
    ) const {
        InMemoryCoverageData result;
        result.sourceFiles = sourceFiles;

        // Build a map from function hash to its counter array
        auto funcCounterMap = buildFunctionCounterMap(globalCounters, count);

        // Debug: print some stats
        // fprintf(stderr, "Coverage mapping has %zu functions\n", functions.size());
        // fprintf(stderr, "Runtime has %zu profile data records\n", funcCounterMap.size());

        for (const auto& func : functions) {
            FunctionCoverage funcCov;
            funcCov.name = func.functionName;
            funcCov.hash = func.functionHash;
            funcCov.executionCount = 0;

            // Find this function's counters by nameRef (MD5 of function name)
            auto it = funcCounterMap.find(func.nameRef);
            if (it == funcCounterMap.end()) {
                // Debug: show functions that couldn't be matched
                if (func.functionName.find("MockDatabase") != std::string::npos ||
                    func.functionName.find("TestStruct") != std::string::npos) {
                    fprintf(stderr, "[DEBUG] No runtime match for: %s (nameRef=0x%llx)\n",
                            func.functionName.c_str(),
                            (unsigned long long)func.nameRef);
                }
                // No runtime data for this function - skip it
                continue;
            }

            const uint64_t* funcCounters = it->second.first;
            uint32_t numCounters = it->second.second;

            // Debug: Print counter values for MockDatabase and TestStruct functions
            bool isMockDb = func.functionName.find("MockDatabase") != std::string::npos;
            bool isTestStruct = func.functionName.find("TestStruct") != std::string::npos;
            if (isMockDb || isTestStruct) {
                bool isWrite = func.functionName.find("write3key5value") != std::string::npos;
                bool isWriteCountInit = func.functionName.find("writeCountSivpfi") != std::string::npos;
                bool isIncrement = func.functionName.find("increment") != std::string::npos;
                bool isGetValue = func.functionName.find("getValue") != std::string::npos;
                bool isValueInit = func.functionName.find("valueSivpfi") != std::string::npos;
                if (isWrite || isWriteCountInit || isIncrement || isGetValue || isValueInit) {
                    const char* label = isWrite ? "write()" : isWriteCountInit ? "writeCountInit" : isIncrement ? "increment()" : isGetValue ? "getValue()" : "valueInit";
                    fprintf(stderr, "[DEBUG] %s nameRef=0x%llx, counters=%p, numCounters=%u, values=[",
                            label, (unsigned long long)func.nameRef, (void*)funcCounters, numCounters);
                    for (uint32_t i = 0; i < numCounters && i < 5; i++) {
                        fprintf(stderr, "%llu%s", (unsigned long long)funcCounters[i],
                                i < numCounters - 1 ? ", " : "");
                    }
                    fprintf(stderr, "]\n");
                    fprintf(stderr, "  funcName: %s\n", func.functionName.c_str());

                    // Print region counter types
                    for (size_t i = 0; i < func.regions.size(); i++) {
                        const auto& region = func.regions[i];
                        const char* kindStr = "Unknown";
                        switch (region.Count.getKind()) {
                            case Counter::Zero: kindStr = "Zero"; break;
                            case Counter::CounterValueReference: kindStr = "CounterRef"; break;
                            case Counter::Expression: kindStr = "Expression"; break;
                        }
                        fprintf(stderr, "  Region %zu: kind=%s, counterId=%u\n",
                                i, kindStr, region.Count.getCounterID());
                    }
                }
            }

            // Create context with this function's counters
            ArrayRef<uint64_t> counterValues(funcCounters, numCounters);
            CounterMappingContext ctx(func.expressions, counterValues);

            for (const auto& region : func.regions) {
                // Skip expansion regions and gap regions for now
                if (region.Kind == CounterMappingRegion::ExpansionRegion ||
                    region.Kind == CounterMappingRegion::SkippedRegion) {
                    continue;
                }

                // Evaluate the counter
                auto countOrErr = ctx.evaluate(region.Count);
                uint64_t execCount = 0;
                if (countOrErr) {
                    execCount = *countOrErr >= 0 ? static_cast<uint64_t>(*countOrErr) : 0;
                }

                // Get filename
                std::string filename;
                if (region.FileID < func.filenames.size()) {
                    filename = func.filenames[region.FileID];
                }

                RegionCoverage regCov;
                regCov.filename = filename;
                regCov.lineStart = region.LineStart;
                regCov.columnStart = region.ColumnStart;
                regCov.lineEnd = region.LineEnd;
                regCov.columnEnd = region.ColumnEnd & 0x7FFFFFFF; // Mask gap region bit
                regCov.executionCount = execCount;
                regCov.isBranch = region.isBranch();

                funcCov.regions.push_back(regCov);

                // First region is typically the function entry
                if (funcCov.regions.size() == 1) {
                    funcCov.executionCount = execCount;
                }
            }

            if (!funcCov.regions.empty()) {
                result.functions.push_back(std::move(funcCov));
            }
        }

        return result;
    }
};

InMemoryCoverageReader::InMemoryCoverageReader() : pImpl(nullptr) {}

InMemoryCoverageReader::~InMemoryCoverageReader() = default;

InMemoryCoverageReader* InMemoryCoverageReader::loadFromCurrentProcess(
    CoverageError& outError
) {
    // First, try to load from all candidate images
    auto candidates = findLoadedImagesWithCoverage();

    // Also add the main executable
    std::string execPath = getCurrentExecutablePath();
    if (!execPath.empty()) {
        candidates.insert(candidates.begin(), execPath);
    }

    // Try each candidate until we find one with coverage data
    std::string lastError;
    for (const auto& path : candidates) {
        CoverageError tryError;
        auto reader = loadFromBinary(path, tryError);
        if (reader && reader->getFunctionCount() > 0) {
            fprintf(stderr, "[DEBUG] Loaded coverage from: %s (%zu functions)\n",
                    path.c_str(), reader->getFunctionCount());
            outError = CoverageError::none();
            return reader;
        }
        if (tryError.hasError) {
            lastError = tryError.message;
        }
        if (reader) {
            destroy(reader);
        }
    }

    if (lastError.empty()) {
        outError = CoverageError::make("No loaded images have coverage mapping data");
    } else {
        outError = CoverageError::make(lastError);
    }
    return nullptr;
}

InMemoryCoverageReader* InMemoryCoverageReader::loadFromBinary(
    const std::string& objectPath,
    CoverageError& outError
) {
    auto impl = Impl::loadFromFile(objectPath, outError);
    if (!impl) {
        return nullptr;
    }

    auto reader = new InMemoryCoverageReader();
    reader->pImpl = std::move(impl);
    return reader;
}

void InMemoryCoverageReader::destroy(InMemoryCoverageReader* reader) {
    delete reader;
}

InMemoryCoverageData InMemoryCoverageReader::resolveCoverage(
    const uint64_t* counters,
    size_t count
) const {
    if (!pImpl) {
        return InMemoryCoverageData{};
    }
    return pImpl->resolveCoverage(counters, count);
}

std::vector<std::string> InMemoryCoverageReader::getSourceFiles() const {
    if (!pImpl) {
        return {};
    }
    return pImpl->sourceFiles;
}

size_t InMemoryCoverageReader::getFunctionCount() const {
    if (!pImpl) {
        return 0;
    }
    return pImpl->functions.size();
}

} // namespace ptk
