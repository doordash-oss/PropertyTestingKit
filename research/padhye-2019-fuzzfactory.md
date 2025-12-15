# FuzzFactory: Domain-Specific Fuzzing with Waypoints

**Paper:** "FuzzFactory: Domain-Specific Fuzzing with Waypoints" (OOPSLA 2019)
**Authors:** Rohan Padhye, Caroline Lemieux, Koushik Sen, Laurent Simon, Hayawardh Vijayakumar
**Source:** https://rohan.padhye.org/files/fuzzfactory-oopsla19.pdf
**GitHub:** https://github.com/rohanpadhye/FuzzFactory

## Paper Summary

Coverage-guided fuzzing has proven highly effective at discovering security vulnerabilities in programs that parse binary data, but traditional approaches optimize solely for code coverage and cannot incorporate domain-specific testing objectives. Researchers have developed specialized fuzzing tools for different goals—finding performance bottlenecks (SlowFuzz, PerfFuzz), maximizing memory allocations (MemLock), handling magic-byte comparisons, and generating valid inputs—but each specialization traditionally required building a distinct fuzzing tool with custom search heuristics and mutation strategies. This resulted in substantial implementation effort, code duplication, and inability to combine multiple testing objectives in a single fuzzing campaign.

FuzzFactory addresses this limitation by introducing a unifying framework that enables developers to create domain-specific fuzzing applications without modifying the core fuzzing algorithm. The key innovation is **waypoints**: intermediate inputs saved during fuzzing because they make domain-specific progress, even if they don't increase code coverage. Users specify how to collect dynamic domain-specific feedback (DSF) during test execution as key-value pairs, and how such feedback should be aggregated across multiple inputs using reducer functions (MAX, bitwise OR, custom functions). FuzzFactory extends AFL's coverage-guided fuzzing by adding a DSF API that allows the fuzzing algorithm to incorporate arbitrary guidance signals alongside traditional edge coverage. The framework implements domains as LLVM compiler passes that inject feedback collection calls at relevant program points (malloc calls, loop back-edges, comparison operations), minimizing runtime overhead.

The authors demonstrate FuzzFactory's versatility by implementing six domain-specific fuzzing applications and evaluating them on Google's fuzzer test suite. Three applications reimplemented prior work (PerfFuzz for performance bugs, MemFuzz for memory issues, magic-byte comparison smoothing) in minimal code (29-355 lines), while three provided novel solutions. Critically, FuzzFactory enables domain composition: multiple domains can be combined via simple command-line flags to create "super-fuzzers" satisfying multiple objectives simultaneously. Composing the comparison-smoothing domain (cmp) with the memory-maximization domain (mem) produced a fuzzer that automatically generated LZ4 bombs and PNG bombs—tiny inputs causing multi-gigabyte allocations—demonstrating synergistic benefits where the composite fuzzer outperformed both AFL and its constituent domains on memory allocation bug discovery. The evaluation showed that domain-specific applications matched or exceeded specialized tools' effectiveness while requiring significantly less implementation effort and enabling unprecedented flexibility through composition.

## Key Strategies/Techniques

1. **Waypoints Abstraction**: Core concept where intermediate inputs making domain-specific progress are saved as "waypoints" regardless of whether they increase code coverage. This decomposes fuzzing into staged objectives, enabling systematic exploration of target behaviors by funneling inputs toward desired properties through increasingly refined intermediate goals.

2. **Domain-Specific Feedback (DSF) API**: Clean interface (`include/waypoints.h`) exposing key-value pairs with aggregation functions. Formally defined as: keys K, values V, aggregation values A, initial value a₀, and reducer function ρ: A × V → A. Programs update DSF maps during execution via instrumentation, and inputs become waypoints if they improve aggregated feedback for any key.

3. **Reducer Functions for Multi-Dimensional Feedback**: Mathematical reducers combine feedback across inputs:
   - **MAX**: Tracks maximum observed values (perf and mem domains)
   - **Bitwise OR**: Accumulates bit patterns (cmp domain for common-bit-counting)
   - **SET**: Direct assignment for validity tracking
   - **INC**: Accumulative addition
   - **Custom**: User-defined functions for specialized logic

4. **Compile-Time LLVM Instrumentation**: Implements domains as LLVM passes injecting DSF API calls at relevant program points. The mem domain instruments malloc/calloc, perf instruments loop back-edges, cmp instruments comparison operations. This approach minimizes runtime overhead compared to binary instrumentation or interpretation.

5. **Common-Bit-Counting for Magic Bytes**: The cmp domain addresses the "magic byte problem" where traditional fuzzing struggles with hard equality constraints (e.g., `if (input == 0xDEADBEEF)`). For each comparison operation, tracks the number of matching bits between operands. An input with 24 matching bits (when previously only 16 matched) becomes a waypoint, gradually guiding the fuzzer toward satisfying equality constraints without requiring exact matches initially.

6. **Domain Composition**: Multiple domains combine seamlessly via environment variables (e.g., `WAYPOINTS=cmp,mem`). The fuzzer maintains separate DSF maps for each domain and saves an input as a waypoint if it makes progress in any domain. Composition is associative, commutative, and requires no inter-domain communication—domains remain completely independent.

7. **Built-in Domain Implementations**:
   - **mem**: Maximizes malloc/calloc arguments to find allocation bugs and OOM conditions (29 LOC)
   - **perf**: Tracks loop execution counts for performance bottlenecks (similar to PerfFuzz)
   - **cmp**: Common-bit-counting for magic bytes, checksums, string/integer comparisons (355 LOC)
   - **valid**: Tracks input validity assumptions to discover validation bypasses
   - **slow**: Monitors execution time directly to find slow inputs
   - **diff**: Incremental fuzzing focusing on newly modified code

8. **Energy Allocation and Seed Selection**: Waypoints receive fuzzing energy (mutation attempts) based on their novelty and potential. Seeds covering rare execution paths or making recent progress receive higher priority, similar to AFL's power schedules but extended to domain-specific metrics.

9. **Corpus Management with Multi-Objective Awareness**: Unlike traditional fuzzers maintaining a single corpus optimizing for coverage, FuzzFactory's corpus includes inputs optimal for different objectives. An input suboptimal for coverage might be optimal for memory allocation, ensuring diverse exploration across all active domains.

10. **Analysis Tools**: Provides `afl-showdsf` for post-fuzzing analysis, replaying saved inputs and aggregating domain-specific metrics across test case collections. Supports both single-input examination and corpus-wide analysis, enabling developers to understand which inputs are valuable for which domains.

## Applicability to PropertyTestingKit

### Directly Applicable Techniques

1. **User-Defined Waypoint API**: PropertyTestingKit can provide an explicit API for reporting domain-specific feedback from test code, sidestepping the need for compile-time instrumentation. Since Swift lacks stable compiler plugin infrastructure and LLVM instrumentation is impractical, a manual API offers maximum flexibility while remaining Swift-idiomatic:
   ```swift
   @Test func testWithCustomDomain() throws {
       try fuzz(seeds: [...]) { (input: String, count: Int) in
           // Report domain-specific feedback
           FuzzContext.report(key: "string_length", value: input.count, reducer: .max)
           FuzzContext.report(key: "product_target",
                            value: abs(input.count * count - 1000),
                            reducer: .min)

           let result = processInput(input, count: count)
           #expect(result.isValid)
       }
   }
   ```

2. **Formalize Value Profile as Domain**: PropertyTestingKit's existing `ValueProfile.swift` already implements domain-specific feedback remarkably similar to FuzzFactory's cmp domain. The `ValueProfileTracker` captures comparison operations, tracks minimum distances to constant targets, and saves inputs making progress (getting closer to magic numbers). This should be formalized as an explicit, composable domain rather than an always-on implicit mechanism.

3. **Domain-Specific Energy Allocation**: Extend corpus entry selection to prioritize inputs making recent domain-specific progress. Currently, `Corpus.swift` has basic rarity scoring; enhance it to track which domain caused each entry to be saved and allocate mutation energy accordingly:
   ```swift
   struct CorpusEntry {
       var input: [Any]
       var signature: CoverageSignature
       var discoveryDomain: FuzzDomain? // Which domain added this as waypoint
       var domainFeedback: [String: Double] // Feedback values per domain
       var mutationEnergy: Double // Computed from domain recency/success
   }
   ```

4. **Multi-Dimensional Corpus Admission**: Modify `Corpus.addIfInteresting()` to save inputs making progress in any active domain, not just coverage. An input should become a corpus entry if it improves coverage OR improves any domain-specific metric:
   ```swift
   func addIfInteresting(
       _ input: [Any],
       signature: CoverageSignature,
       domainFeedback: [String: DomainFeedbackValue]
   ) -> Bool {
       let hasNewCoverage = signature.hasUniqueCoverage(compared: entries)
       let hasNewDomainProgress = domainFeedback.contains { key, value in
           value.improves(over: bestDomainFeedback[key])
       }

       if hasNewCoverage || hasNewDomainProgress {
           entries.append(CorpusEntry(input, signature, domainFeedback))
           return true
       }
       return false
   }
   ```

5. **Common-Bit-Counting for Magic Bytes**: The value profile's distance tracking can be enhanced with bit-level feedback. When comparisons involve specific constants, track bitwise similarity:
   ```swift
   func trackComparison<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) {
       let xor = lhs ^ rhs
       let matchingBits = T.bitWidth - xor.nonzeroBitCount
       FuzzContext.report(key: "cmp_\(lhs)_\(rhs)", value: matchingBits, reducer: .max)
   }
   ```

### Techniques Requiring Adaptation

1. **Domain Composition**: FuzzFactory's seamless composition (WAYPOINTS=cmp,mem) requires architectural changes but is achievable. Introduce a `FuzzDomain` protocol and allow multiple domains to be active simultaneously:
   ```swift
   protocol FuzzDomain {
       var name: String { get }
       func collectFeedback(during execution: () -> Void) -> [String: DomainFeedbackValue]
       func shouldSaveAsWaypoint(_ feedback: [String: DomainFeedbackValue]) -> Bool
       func suggestMutations(for entry: CorpusEntry) -> [MutationStrategy]
   }

   // Usage
   @Test func testComposed() throws {
       try fuzz(
           domains: [ValueProfileDomain(), OptionalDomain(), CollectionSizeDomain()],
           seeds: [...]
       ) { input in
           // Test logic - all domains collect feedback automatically
       }
   }
   ```

2. **Compile-Time Instrumentation Alternative**: Since LLVM instrumentation is impractical, PropertyTestingKit can leverage Swift's runtime capabilities:
   - Use existing SanitizeCoverage for edge coverage (already implemented)
   - Extend value profile tracking to more comparison types
   - Provide runtime hooks for common operations (Optional unwrapping, collection access)
   - Offer macros for common instrumentation patterns once Swift macros mature

3. **Persistent Learning Infrastructure**: FuzzFactory assumes continuous fuzzing campaigns. PropertyTestingKit's short test runs (60s default) limit learning, but a persistent knowledge base can transfer insights across runs:
   ```swift
   // ~/.propertytestingkit/knowledge.db stores cross-test learning
   class FuzzKnowledgeBase {
       func seedsFor(type: Any.Type) -> [Any] {
           // Return historically effective values for this type
           // E.g., for Int: [0, 1, -1, Int.max, 0xDEADBEEF, ...]
       }

       func recordSuccess(value: Any, coverage: CoverageSignature) {
           // Store successful values for future runs
       }
   }
   ```

### Techniques Not Directly Applicable

1. **Low-Level Memory Domain (mem)**: Tracking malloc sizes is less relevant for Swift with ARC and value semantics. However, an analogous "allocation domain" could track:
   - Large collection allocations (Array.reserveCapacity, Dictionary with many entries)
   - Expensive copy operations (large struct copies, String duplications)
   - Retain/release cycles indicating reference counting pressure

2. **Loop Count Domain (perf)**: Detecting performance issues via loop counts requires instrumentation PropertyTestingKit lacks. Alternative approaches:
   - Time-based feedback (track execution duration per input)
   - Detect divergence via timeout mechanisms
   - Use SwiftSyntax to estimate complexity statically and weight test generation

3. **Binary-Level Instrumentation**: FuzzFactory's LLVM passes operate on LLVM IR. Swift compiles through LLVM but doesn't expose stable IR-level instrumentation hooks. PropertyTestingKit must work at the source/runtime level, accepting higher overhead in exchange for Swift compatibility.

4. **Automatic Domain Discovery**: FuzzFactory domains are manually implemented. Automated domain discovery (analyzing code to identify interesting metrics) remains research-level and is especially challenging in Swift with its rich type system and protocol-oriented design.

## Concrete Recommendations

### 1. Implement User-Defined Waypoint API (Priority: HIGH)

Add explicit domain-specific feedback API to `PropertyTestingKit`:

**New file: `Sources/PropertyTestingKit/Fuzzing/FuzzContext.swift`**
```swift
/// Thread-local context for reporting domain-specific feedback during fuzzing
public final class FuzzContext {
    private static let current = ThreadLocal<FuzzContext?>()

    private(set) var feedback: [String: DomainFeedbackValue] = [:]

    public static func report(
        key: String,
        value: Double,
        reducer: FeedbackReducer = .max
    ) {
        guard let context = current.value else {
            // Not in fuzzing context, ignore
            return
        }

        let newValue = DomainFeedbackValue(value: value, reducer: reducer)
        if let existing = context.feedback[key] {
            context.feedback[key] = existing.reduce(with: newValue)
        } else {
            context.feedback[key] = newValue
        }
    }

    public static func reportFlag(_ key: String) {
        report(key: key, value: 1.0, reducer: .bitwiseOr)
    }

    internal static func withContext<T>(_ body: () -> T) -> (T, [String: DomainFeedbackValue]) {
        let context = FuzzContext()
        current.value = context
        defer { current.value = nil }

        let result = body()
        return (result, context.feedback)
    }
}
```

**New file: `Sources/PropertyTestingKit/Fuzzing/FeedbackReducer.swift`**
```swift
public enum FeedbackReducer {
    case max      // Track maximum value
    case min      // Track minimum value
    case bitwiseOr // Accumulate bits
    case set      // Direct assignment (last wins)
    case increment // Sum values
}

public struct DomainFeedbackValue: Codable {
    public let value: Double
    public let reducer: FeedbackReducer

    public func reduce(with other: DomainFeedbackValue) -> DomainFeedbackValue {
        assert(reducer == other.reducer, "Cannot reduce with different reducers")

        let newValue: Double
        switch reducer {
        case .max:
            newValue = max(value, other.value)
        case .min:
            newValue = min(value, other.value)
        case .bitwiseOr:
            newValue = Double(Int(value) | Int(other.value))
        case .set:
            newValue = other.value
        case .increment:
            newValue = value + other.value
        }

        return DomainFeedbackValue(value: newValue, reducer: reducer)
    }

    public func improves(over baseline: DomainFeedbackValue?) -> Bool {
        guard let baseline = baseline else { return true }

        switch reducer {
        case .max:
            return value > baseline.value
        case .min:
            return value < baseline.value
        case .bitwiseOr:
            return Int(value) & ~Int(baseline.value) != 0 // New bits set
        case .set:
            return value != baseline.value
        case .increment:
            return value > baseline.value
        }
    }
}
```

**Usage example:**
```swift
@Test func testParserWithDomainFeedback() throws {
    try fuzz(seeds: ["", "{}", "{\"key\": \"value\"}"]) { (input: String) in
        // Report how deeply nested the JSON is
        let nestingLevel = input.filter { $0 == "{" }.count
        FuzzContext.report(key: "json_nesting", value: Double(nestingLevel), reducer: .max)

        // Report string length to guide toward interesting sizes
        FuzzContext.report(key: "input_length", value: Double(input.count), reducer: .max)

        // Report parsing stage reached
        if let parsed = try? JSONParser.parse(input) {
            FuzzContext.reportFlag("parse_success")
            FuzzContext.report(key: "object_count",
                             value: Double(parsed.objectCount),
                             reducer: .max)
        }

        #expect(/* properties that should hold */)
    }
}
```

### 2. Formalize Value Profile as Composable Domain (Priority: HIGH)

Refactor existing value profile to conform to domain protocol:

**New file: `Sources/PropertyTestingKit/Fuzzing/FuzzDomain.swift`**
```swift
public protocol FuzzDomain {
    var name: String { get }

    /// Collect feedback during test execution
    func collectFeedback<T>(during execution: () -> T) -> (T, [String: DomainFeedbackValue])

    /// Determine if feedback represents progress worth saving as waypoint
    func shouldSaveAsWaypoint(
        _ feedback: [String: DomainFeedbackValue],
        compared bestFeedback: [String: DomainFeedbackValue]
    ) -> Bool

    /// Suggest mutations based on feedback (optional)
    func suggestMutations(
        for entry: CorpusEntry,
        targeting feedback: [String: DomainFeedbackValue]
    ) -> [MutationStrategy]
}

public extension FuzzDomain {
    func suggestMutations(
        for entry: CorpusEntry,
        targeting feedback: [String: DomainFeedbackValue]
    ) -> [MutationStrategy] {
        [] // Default: no domain-specific mutations
    }
}
```

**Modify `Sources/PropertyTestingKit/Fuzzing/ValueProfile.swift`:**
```swift
public struct ValueProfileDomain: FuzzDomain {
    public let name = "value_profile"

    public func collectFeedback<T>(during execution: () -> T) -> (T, [String: DomainFeedbackValue]) {
        let tracker = ValueProfileTracker()
        ValueProfileTracker.current = tracker
        defer { ValueProfileTracker.current = nil }

        let result = execution()

        // Convert value profile distances to domain feedback
        var feedback: [String: DomainFeedbackValue] = [:]
        for (location, distance) in tracker.minimumDistances {
            let key = "vp_\(location.file)_\(location.line)_\(location.column)"
            feedback[key] = DomainFeedbackValue(value: -Double(distance), reducer: .max)
        }

        return (result, feedback)
    }

    public func shouldSaveAsWaypoint(
        _ feedback: [String: DomainFeedbackValue],
        compared bestFeedback: [String: DomainFeedbackValue]
    ) -> Bool {
        // Save if any distance improved
        for (key, value) in feedback {
            if value.improves(over: bestFeedback[key]) {
                return true
            }
        }
        return false
    }

    public func suggestMutations(
        for entry: CorpusEntry,
        targeting feedback: [String: DomainFeedbackValue]
    ) -> [MutationStrategy] {
        // Extract comparison targets and suggest value-profile-guided mutations
        let targets = extractComparisonTargets(from: feedback)
        return targets.map { .targetedArithmetic($0) }
    }
}
```

### 3. Add Optional Unwrapping Domain (Priority: MEDIUM)

Track Optional state transitions to discover nil-handling bugs:

**New file: `Sources/PropertyTestingKit/Fuzzing/Domains/OptionalDomain.swift`**
```swift
public struct OptionalDomain: FuzzDomain {
    public let name = "optional"

    // Track which optionals have been seen as nil vs non-nil
    private static var optionalStates = ThreadLocal<[String: OptionalState]>()

    private enum OptionalState: Int {
        case neverSeen = 0
        case seenNil = 1
        case seenValue = 2
        case seenBoth = 3 // 1 | 2
    }

    public static func trackOptional<T>(_ value: T?, at location: String) {
        guard var states = optionalStates.value else { return }

        let current = states[location] ?? .neverSeen
        let newState: OptionalState = value == nil ? .seenNil : .seenValue
        states[location] = OptionalState(rawValue: current.rawValue | newState.rawValue)!

        optionalStates.value = states
    }

    public func collectFeedback<T>(during execution: () -> T) -> (T, [String: DomainFeedbackValue]) {
        OptionalDomain.optionalStates.value = [:]
        defer { OptionalDomain.optionalStates.value = nil }

        let result = execution()

        // Convert optional states to feedback
        var feedback: [String: DomainFeedbackValue] = [:]
        if let states = OptionalDomain.optionalStates.value {
            for (location, state) in states {
                let key = "opt_\(location)"
                feedback[key] = DomainFeedbackValue(
                    value: Double(state.rawValue),
                    reducer: .bitwiseOr
                )
            }
        }

        return (result, feedback)
    }

    public func shouldSaveAsWaypoint(
        _ feedback: [String: DomainFeedbackValue],
        compared bestFeedback: [String: DomainFeedbackValue]
    ) -> Bool {
        // Save if we see a new optional state (nil→value or value→nil transition)
        for (key, value) in feedback {
            if value.improves(over: bestFeedback[key]) {
                return true
            }
        }
        return false
    }
}

// Macro for automatic instrumentation (when Swift macros mature)
@freestanding(expression)
public macro trackOptional<T>(_ value: T?) -> T? = #externalMacro(
    module: "PropertyTestingKitMacros",
    type: "TrackOptionalMacro"
)

// Manual usage until macro available
public func trackOptional<T>(
    _ value: T?,
    file: String = #file,
    line: Int = #line
) -> T? {
    OptionalDomain.trackOptional(value, at: "\(file):\(line)")
    return value
}
```

**Usage:**
```swift
@Test func testWithOptionalTracking() throws {
    try fuzz(domains: [OptionalDomain()], seeds: [...]) { (input: String?) in
        // Automatically tracks nil vs non-nil states
        let processed = trackOptional(processInput(input))

        if let value = processed {
            #expect(value.isValid)
        }
    }
}
```

### 4. Implement Domain-Aware Corpus Selection (Priority: HIGH)

Extend corpus entry metadata and selection algorithm:

**Modify `Sources/PropertyTestingKit/Fuzzing/Corpus.swift`:**
```swift
public struct CorpusEntry: Codable {
    public let input: [SerializableFuzzValue]
    public let signature: CoverageSignature
    public let parentIndex: Int?
    public let discoveryIteration: Int

    // New domain-specific fields
    public let discoveryDomain: String? // Which domain caused this to be saved
    public let domainFeedback: [String: DomainFeedbackValue] // Feedback per domain
    public var mutationSuccesses: Int = 0 // How many mutations from this entry found new waypoints
    public var mutationAttempts: Int = 0

    public var successRate: Double {
        mutationAttempts > 0 ? Double(mutationSuccesses) / Double(mutationAttempts) : 0.0
    }
}

extension Corpus {
    public mutating func selectForMutation(
        iteration: Int,
        domains: [FuzzDomain]
    ) -> CorpusEntry? {
        guard !entries.isEmpty else { return nil }

        // Compute energy (mutation priority) for each entry
        var energies: [Double] = entries.map { entry in
            var energy = 1.0

            // Rarity bonus (existing logic)
            let rarityBonus = computeRarityBonus(for: entry)
            energy += rarityBonus

            // Recency bonus - recent discoveries get more energy
            let age = iteration - entry.discoveryIteration
            let recencyBonus = max(0, 10.0 - Double(age) / 100.0)
            energy += recencyBonus

            // Success rate bonus - entries that frequently lead to discoveries
            if entry.mutationAttempts >= 5 {
                energy += entry.successRate * 5.0
            }

            // Domain-specific bonus - entries making progress in multiple domains
            let domainDiversity = entry.domainFeedback.count
            energy += Double(domainDiversity) * 2.0

            return max(1.0, energy)
        }

        // Sample weighted by energy
        let totalEnergy = energies.reduce(0, +)
        let threshold = Double.random(in: 0..<totalEnergy)
        var cumulative = 0.0

        for (index, energy) in energies.enumerated() {
            cumulative += energy
            if cumulative >= threshold {
                return entries[index]
            }
        }

        return entries.last
    }

    public mutating func addIfInteresting(
        _ input: [SerializableFuzzValue],
        signature: CoverageSignature,
        domainFeedback: [String: DomainFeedbackValue],
        domains: [FuzzDomain],
        parentIndex: Int?,
        iteration: Int
    ) -> Bool {
        // Check coverage progress (existing logic)
        let hasNewCoverage = !entries.contains { $0.signature.contains(signature) }

        // Check domain-specific progress
        var discoveryDomain: String?
        for domain in domains {
            let bestFeedback = entries
                .filter { $0.discoveryDomain == domain.name }
                .last?
                .domainFeedback ?? [:]

            if domain.shouldSaveAsWaypoint(domainFeedback, compared: bestFeedback) {
                discoveryDomain = domain.name
                break
            }
        }

        let hasNewDomainProgress = discoveryDomain != nil

        if hasNewCoverage || hasNewDomainProgress {
            let entry = CorpusEntry(
                input: input,
                signature: signature,
                parentIndex: parentIndex,
                discoveryIteration: iteration,
                discoveryDomain: discoveryDomain,
                domainFeedback: domainFeedback
            )
            entries.append(entry)

            // Update parent's success counter
            if let parentIdx = parentIndex, parentIdx < entries.count - 1 {
                entries[parentIdx].mutationSuccesses += 1
            }

            return true
        }

        return false
    }
}
```

### 5. Create Persistent Fuzzing Knowledge Base (Priority: MEDIUM)

Store effective values across test runs:

**New file: `Sources/PropertyTestingKit/Fuzzing/KnowledgeBase.swift`**
```swift
import Foundation
import SQLite3

public class FuzzKnowledgeBase {
    private let dbPath: String
    private var db: OpaquePointer?

    public static let shared = FuzzKnowledgeBase()

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let pkgDir = homeDir.appendingPathComponent(".propertytestingkit")
        try? FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        self.dbPath = pkgDir.appendingPathComponent("knowledge.db").path
        initializeDatabase()
    }

    private func initializeDatabase() {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("Failed to open knowledge base")
            return
        }

        let schema = """
        CREATE TABLE IF NOT EXISTS effective_values (
            type TEXT NOT NULL,
            value_json TEXT NOT NULL,
            discovery_date INTEGER NOT NULL,
            success_count INTEGER DEFAULT 1,
            last_used INTEGER,
            PRIMARY KEY (type, value_json)
        );

        CREATE INDEX IF NOT EXISTS idx_type_success
        ON effective_values(type, success_count DESC);

        CREATE TABLE IF NOT EXISTS domain_insights (
            domain TEXT NOT NULL,
            key TEXT NOT NULL,
            value REAL NOT NULL,
            discovery_date INTEGER NOT NULL,
            PRIMARY KEY (domain, key)
        );
        """

        sqlite3_exec(db, schema, nil, nil, nil)
    }

    public func recordEffectiveValue<T: Codable>(_ value: T) {
        let typeName = String(describing: T.self)
        guard let jsonData = try? JSONEncoder().encode(value),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let sql = """
        INSERT INTO effective_values (type, value_json, discovery_date)
        VALUES (?, ?, ?)
        ON CONFLICT(type, value_json) DO UPDATE SET
            success_count = success_count + 1,
            last_used = ?;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        let now = Int(Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 1, typeName, -1, nil)
        sqlite3_bind_text(stmt, 2, jsonString, -1, nil)
        sqlite3_bind_int64(stmt, 3, Int64(now))
        sqlite3_bind_int64(stmt, 4, Int64(now))

        sqlite3_step(stmt)
    }

    public func effectiveValues<T: Codable>(for type: T.Type, limit: Int = 20) -> [T] {
        let typeName = String(describing: type)
        let sql = """
        SELECT value_json FROM effective_values
        WHERE type = ?
        ORDER BY success_count DESC, last_used DESC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        sqlite3_bind_text(stmt, 1, typeName, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let jsonString = sqlite3_column_text(stmt, 0),
                  let jsonData = String(cString: jsonString).data(using: .utf8),
                  let value = try? JSONDecoder().decode(T.self, from: jsonData) else {
                continue
            }
            results.append(value)
        }

        return results
    }

    public func recordDomainInsight(domain: String, key: String, value: Double) {
        let sql = """
        INSERT INTO domain_insights (domain, key, value, discovery_date)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(domain, key) DO UPDATE SET
            value = MAX(value, excluded.value);
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        let now = Int(Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 1, domain, -1, nil)
        sqlite3_bind_text(stmt, 2, key, -1, nil)
        sqlite3_bind_double(stmt, 3, value)
        sqlite3_bind_int64(stmt, 4, Int64(now))

        sqlite3_step(stmt)
    }
}

// Integration with fuzz engine
extension FuzzEngine {
    func seedFromKnowledgeBase<T: Codable>(_ type: T.Type) -> [T] {
        FuzzKnowledgeBase.shared.effectiveValues(for: type)
    }

    func recordSuccessfulCorpusEntry(_ entry: CorpusEntry) {
        for value in entry.input {
            // Record each component as effective
            // (requires SerializableFuzzValue to be Codable)
        }

        // Record domain insights
        for (key, feedback) in entry.domainFeedback {
            if let domain = entry.discoveryDomain {
                FuzzKnowledgeBase.shared.recordDomainInsight(
                    domain: domain,
                    key: key,
                    value: feedback.value
                )
            }
        }
    }
}
```

### 6. Enhanced Fuzz Function with Domain Support (Priority: HIGH)

Extend the main `fuzz()` function to accept domains:

**Modify `Sources/PropertyTestingKit/Fuzzing/Fuzz.swift`:**
```swift
public func fuzz<each Input: Fuzzable>(
    seeds: [(repeat each Input)]? = nil,
    domains: [FuzzDomain] = [ValueProfileDomain()], // Default to value profile only
    iterations: Int? = nil,
    duration: TimeInterval? = nil,
    corpusMode: CorpusMode = .auto,
    file: String = #file,
    function: String = #function,
    test: (repeat each Input) throws -> Void
) throws {
    let engine = FuzzEngine(
        domains: domains,
        iterations: iterations,
        duration: duration,
        corpusMode: corpusMode
    )

    // Seed from knowledge base
    let knowledgeSeeds = loadSeedsFromKnowledgeBase(repeat (each Input).self)

    // Combine user seeds + knowledge base seeds
    let allSeeds = (seeds ?? []) + knowledgeSeeds

    try engine.fuzz(seeds: allSeeds) { (args: (repeat each Input)) in
        // Collect feedback from all domains
        var allFeedback: [String: DomainFeedbackValue] = [:]

        for domain in domains {
            let (_, domainFeedback) = domain.collectFeedback {
                try test(repeat each args)
            }
            allFeedback.merge(domainFeedback) { existing, new in
                existing.reduce(with: new)
            }
        }

        return allFeedback
    }
}
```

### Implementation Priority and Timeline

**Phase 1 (Q1 2025): Foundation - 4-6 weeks**
- User-Defined Waypoint API (#1) - 1 week
- FuzzDomain protocol and refactor value profile (#2) - 2 weeks
- Domain-aware corpus selection (#4) - 1-2 weeks
- Enhanced fuzz function with domain support (#6) - 1 week

**Phase 2 (Q2 2025): Core Domains - 4-6 weeks**
- Optional Unwrapping Domain (#3) - 1-2 weeks
- Collection Size Domain - 2 weeks
- Arithmetic Relationship Domain - 2-3 weeks

**Phase 3 (Q3 2025): Infrastructure - 3-4 weeks**
- Persistent Fuzzing Knowledge Base (#5) - 2-3 weeks
- Testing and optimization - 1-2 weeks

**Phase 4 (Q4 2025+): Advanced Features**
- Domain composition refinement
- Additional built-in domains (Result/Error tracking, String pattern domain)
- Performance optimization
- Swift macro integration (when stable)

### Key Insights and Lessons

1. **Manual Instrumentation is Acceptable**: FuzzFactory's automatic LLVM instrumentation is elegant but not essential. PropertyTestingKit's explicit API approach trades some convenience for Swift compatibility and flexibility. Users explicitly reporting feedback aligns with Swift's philosophy of clarity over magic.

2. **Value Profile is Already a Domain**: PropertyTestingKit has already independently discovered domain-specific feedback through its value profile implementation. This validates FuzzFactory's approach and shows the natural evolution from coverage-only to multi-dimensional feedback.

3. **Composition Enables Super-Fuzzers**: The most compelling FuzzFactory result is domain composition (cmp+mem finding PNG/LZ4 bombs). PropertyTestingKit should prioritize composability from the start, ensuring multiple domains can coexist and reinforce each other.

4. **Waypoints vs Coverage is Key Insight**: The fundamental realization that "interesting inputs" include more than "inputs increasing coverage" applies directly to PropertyTestingKit. Inputs making progress toward magic numbers, nil/non-nil boundaries, or user-defined objectives should be corpus members even without coverage gains.

5. **Swift-Specific Domains are Valuable**: Rather than directly porting FuzzFactory's C-focused domains (malloc tracking, loop counts), PropertyTestingKit should focus on Swift-idiomatic domains: Optional states, Result patterns, collection sizes, protocol conformances, enum case coverage.

6. **Knowledge Base Addresses Short Runs**: FuzzFactory assumes continuous fuzzing; PropertyTestingKit has 60-second test runs. A persistent knowledge base enables learning accumulation across short runs, effectively simulating continuous campaigns.

7. **Start Simple, Compose Later**: Begin with 2-3 domains (value profile, optional, user-defined) proven to work independently before tackling complex composition. Validate the architecture scales before adding many domains.

## Sources

- [FuzzFactory paper (author's website)](https://rohan.padhye.org/files/fuzzfactory-oopsla19.pdf)
- [FuzzFactory GitHub repository](https://github.com/rohanpadhye/FuzzFactory)
- [SPLASH 2019 presentation](https://2019.splashcon.org/details/splash-2019-oopsla/57/FuzzFactory-Domain-Specific-Fuzzing-with-Waypoints)
- [Domain-specific fuzzing blog post](https://www.c0d3xpl0it.com/2019/12/domain-specific-fuzzing-with-waypoints.html)
