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
