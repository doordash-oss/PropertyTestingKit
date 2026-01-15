# Future Directions

Potential improvements and optimizations that have been investigated but not yet implemented.

## Input Deduplication

**Status:** Investigated, not pursuing now

**Summary:** Track tested inputs during a fuzz run to avoid re-testing duplicates.

**Findings (1000 iterations):**

| Input Type | Duplicate Rate |
|------------|----------------|
| Int | 24.7% |
| String | 16.9% |
| [Int] | 10.5% |
| (Int, String, Bool, Double, UInt8) | 0.0% |

**Analysis:**
- Single-input fuzzing has 10-25% duplicate rates due to overlapping mutations
- Multi-input fuzzing (2+ types) has near-zero duplicates because the search space grows exponentially with each input type
- Since most real-world usage involves 2+ input types, the benefit is minimal

**Implementation notes:**
- Duplicate tracking was prototyped using `PropertyListEncoder` (binary format) to handle `Double.nan`/`infinity`
- `JSONEncoder` cannot encode special float values
- Each input must be wrapped in an array for PropertyListEncoder (top-level fragments not allowed)

**Decision:** Not worth pursuing since multi-input fuzzing (the common case) already has negligible duplicate rates.

## Bitpacked Coverage Counters

**Status:** Investigated, not pursuing now

**Summary:** Pack coverage counters as 1 bit per edge instead of 1 byte per edge, reducing memory footprint 8x.

**Trade-offs:**

| Aspect | Byte Array (current) | Bitpacked |
|--------|---------------------|-----------|
| Memory | N bytes | N/8 bytes |
| Write | `map[i] = 1` | `map[i/8] \|= (1 << (i&7))` |
| Read | `map[i] != 0` | `(map[i/8] >> (i&7)) & 1` |
| SIMD scan | 16 edges per load | 128 edges per load (complex extraction) |

**Cache analysis (Apple Silicon):**

| Edges | Byte array | Bitpacked | L1D fit? |
|-------|-----------|-----------|----------|
| 50K   | 50KB      | 6.25KB    | Both fit |
| 100K  | 100KB     | 12.5KB    | Bitpacked only |
| 200K  | 200KB     | 25KB      | Bitpacked only |

- P-cores: 128KB L1D, 16MB L2
- E-cores: 64KB L1D, 4MB L2

**Analysis:**
- Bitpacking wins for large edge counts (>64K) where byte array spills L1
- Extra ALU ops (shifts, masks) are essentially free on superscalar CPUs
- SIMD extraction of set bit positions is more complex than byte comparison
- L2 cache is very fast on Apple Silicon, so spilling L1 isn't catastrophic

**Decision:** Not worth the complexity. Typical test binaries have 50K-200K edges. The byte array fits in L2, and L2 is fast enough that the gains don't justify the added complexity.

## Silent Issue Detection During Shrinking

**Status:** Blocked by Swift Testing API limitations

**Summary:** The test case shrinker needs to detect when `#expect` fails to know if a shrunk input still triggers the failure. Currently, it uses `withKnownIssue` which logs each failure as a "known issue", producing noisy output during shrinking.

**Goal:** Detect `#expect` failures without recording any issues (known or otherwise).

**Findings:**

Swift Testing's issue suppression mechanism (Issue Handling Traits, ST-0011) works via `Configuration.withCurrent`, which wraps the event handler to intercept `.issueRecorded` events. However:

- `Configuration.withCurrent` is `internal`, not `public`
- `@testable import Testing` fails because the Testing framework is compiled without `-enable-testing`
- Issue Handling Traits (`.filterIssues`, `.compactMapIssues`) only work as test annotations (`@Test(.filterIssues {...})`), not as runtime APIs
- There is no public API to programmatically suppress issue recording

**Current behavior:**
```
◯ Test "..." recorded a known issue at ...: Expectation failed: ...
◯ Test "..." recorded a known issue at ...: Expectation failed: ...
◯ Test "..." passed after 0.006 seconds with 8 known issues.
```

The test passes correctly; the known issues are just noise in the output.

**Potential future solutions:**

1. **Swift Testing adds public API** - If `Configuration.withCurrent` becomes public or a programmatic issue filtering API is added, we could suppress issues during shrinking.

2. **Custom check function** - Provide `fuzzCheck(_ condition: Bool) throws` that users use instead of `#expect` inside fuzz closures. It would throw on failure instead of recording an issue.

3. **Change fuzz API** - Require fuzz closures to return `Bool` or throw errors explicitly instead of using `#expect`.

**Decision:** Accept current behavior. Known issues during shrinking are cosmetic noise but don't affect correctness. Revisit if Swift Testing adds a public issue suppression API.
