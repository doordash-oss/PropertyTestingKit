//
//  LLVMCoverageInterop.hpp
//  PropertyTestingKit
//
//  C++ wrapper around LLVM's coverage APIs for Swift interop.
//

#ifndef LLVM_COVERAGE_INTEROP_HPP
#define LLVM_COVERAGE_INTEROP_HPP

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Swift interop attributes
#if __has_attribute(swift_attr)
#define SWIFT_IMMORTAL_REFERENCE __attribute__((swift_attr("import_reference"))) \
    __attribute__((swift_attr("retain:immortal"))) \
    __attribute__((swift_attr("release:immortal")))
#else
#define SWIFT_IMMORTAL_REFERENCE
#endif

// Forward declarations to avoid exposing LLVM headers
namespace llvm {
namespace coverage {
class CoverageMapping;
class CoverageData;
}
}

namespace ptk {

/// Statistics for a single line of code.
struct LineCoverage {
    uint32_t line;
    uint64_t executionCount;
    bool isMapped;
    bool hasMultipleRegions;
};

/// Coverage information for a single file.
struct FileCoverage {
    std::string filename;
    std::vector<LineCoverage> lines;
    uint64_t coveredLines;
    uint64_t totalLines;
};

/// Summary of coverage for the entire binary.
struct CoverageSummary {
    uint64_t totalFunctions;
    uint64_t coveredFunctions;
    uint64_t totalLines;
    uint64_t coveredLines;
    uint64_t totalRegions;
    uint64_t coveredRegions;
};

/// Error information from coverage operations.
struct CoverageError {
    bool hasError;
    std::string message;

    static CoverageError none() {
        return CoverageError{false, ""};
    }

    static CoverageError make(const std::string& msg) {
        return CoverageError{true, msg};
    }
};

/// Main wrapper class for LLVM coverage data.
///
/// Usage:
/// ```cpp
/// CoverageError error;
/// auto reader = CoverageReader::load("binary", "profile.profdata", error);
/// if (error.hasError) { /* handle error */ }
/// auto files = reader->getSourceFiles();
/// auto coverage = reader->getFileCoverage(files[0]);
/// CoverageReader::destroy(reader);
/// ```
class SWIFT_IMMORTAL_REFERENCE CoverageReader {
public:
    /// Load coverage data from a binary and profile.
    ///
    /// @param objectPath Path to the instrumented binary.
    /// @param profilePath Path to the .profdata file.
    /// @param outError Output parameter for error information.
    /// @return Pointer to reader, or nullptr on failure. Caller must call destroy().
    static CoverageReader* load(const std::string& objectPath,
                                const std::string& profilePath,
                                CoverageError& outError);

    /// Destroy a coverage reader created with load().
    static void destroy(CoverageReader* reader);

    ~CoverageReader();

    // Prevent copying
    CoverageReader(const CoverageReader&) = delete;
    CoverageReader& operator=(const CoverageReader&) = delete;

    /// Get list of all source files with coverage data.
    std::vector<std::string> getSourceFiles() const;

    /// Get coverage information for a specific file.
    FileCoverage getFileCoverage(const std::string& filename) const;

    /// Get overall coverage summary.
    CoverageSummary getSummary() const;

    /// Get the execution count for a specific line in a file.
    /// Returns 0 if the line is not covered or not mapped.
    uint64_t getLineExecutionCount(const std::string& filename, uint32_t line) const;

    /// Check if a specific line was executed at least once.
    bool isLineCovered(const std::string& filename, uint32_t line) const;

private:
    CoverageReader();

    struct Impl;
    std::unique_ptr<Impl> pImpl;
};

// MARK: - In-Memory Coverage Reader

/// A source region with its execution count.
struct RegionCoverage {
    std::string filename;
    uint32_t lineStart;
    uint32_t columnStart;
    uint32_t lineEnd;
    uint32_t columnEnd;
    uint64_t executionCount;
    bool isBranch;
};

/// Function coverage record with resolved execution counts.
struct FunctionCoverage {
    std::string name;           // Mangled name
    std::string demangledName;  // Human-readable demangled name
    uint64_t hash;
    std::vector<RegionCoverage> regions;
    uint64_t executionCount;    // Entry count
};

/// Coverage data resolved from in-memory counters.
struct InMemoryCoverageData {
    std::vector<FunctionCoverage> functions;
    std::vector<std::string> sourceFiles;
};

/// Reader that parses coverage mapping from binary and resolves
/// with in-memory counter values.
///
/// This avoids the profraw → profdata pipeline entirely.
///
/// Usage:
/// ```cpp
/// CoverageError error;
/// auto reader = InMemoryCoverageReader::loadFromCurrentProcess(error);
/// if (!error.hasError) {
///     // Get current counter values
///     uint64_t* counters = __llvm_profile_begin_counters();
///     size_t count = __llvm_profile_end_counters() - counters;
///
///     // Resolve to source-level coverage
///     auto coverage = reader->resolveCoverage(counters, count);
/// }
/// InMemoryCoverageReader::destroy(reader);
/// ```
class SWIFT_IMMORTAL_REFERENCE InMemoryCoverageReader {
public:
    /// Load coverage mapping from the current process's binary.
    ///
    /// This parses the __llvm_covmap and __llvm_covfun sections
    /// from the executable. This is a one-time operation.
    ///
    /// @param outError Output parameter for error information.
    /// @return Pointer to reader, or nullptr on failure.
    static InMemoryCoverageReader* loadFromCurrentProcess(CoverageError& outError);

    /// Load coverage mapping from a specific binary.
    ///
    /// @param objectPath Path to the instrumented binary.
    /// @param outError Output parameter for error information.
    /// @return Pointer to reader, or nullptr on failure.
    static InMemoryCoverageReader* loadFromBinary(
        const std::string& objectPath,
        CoverageError& outError
    );

    /// Destroy a reader created with load methods.
    static void destroy(InMemoryCoverageReader* reader);

    ~InMemoryCoverageReader();

    // Prevent copying
    InMemoryCoverageReader(const InMemoryCoverageReader&) = delete;
    InMemoryCoverageReader& operator=(const InMemoryCoverageReader&) = delete;

    /// Resolve coverage using in-memory counter values.
    ///
    /// @param counters Pointer to the counter array (from __llvm_profile_begin_counters).
    /// @param count Number of counters.
    /// @return Coverage data with resolved execution counts.
    InMemoryCoverageData resolveCoverage(
        const uint64_t* counters,
        size_t count
    ) const;

    /// Get the list of source files from the coverage mapping.
    std::vector<std::string> getSourceFiles() const;

    /// Get the number of functions in the coverage mapping.
    size_t getFunctionCount() const;

private:
    InMemoryCoverageReader();

    struct Impl;
    std::unique_ptr<Impl> pImpl;
};

} // namespace ptk

#endif // LLVM_COVERAGE_INTEROP_HPP
