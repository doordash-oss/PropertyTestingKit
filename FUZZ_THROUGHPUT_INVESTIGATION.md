# Fuzz Throughput & Interleaving Investigation

## Problem 1: "Only 4 iterations in 3s" for uncontrolled fuzz

### Root cause

The fuzz engine auto-detected a saved corpus file and ran in **regression mode**,
replaying the 4 saved corpus entries instead of fuzzing. `stats.totalInputs`
showed 4 because it counted 4 replays, not 4 fuzz iterations.

### Fix

Pass `corpusMode: .refuzzReplace` to force fresh fuzzing. After the fix:

| Test | Before | After |
|---|---|---|
| uncontrolledConstantInputManyPaths | 4 "iterations" (replay) | ~240,000 iter/s actual fuzzing |
| controlledConstantInputReproducible | 2 "iterations" (replay) | ~1,500 iter/s (schedule-controlled) |

## Problem 2: Only ~3 corpus entries for concurrent subscribe/cancel

### Expected: "It should be interleaving like crazy"

### Measured (200 iterations, direct body execution)

- **With full edge filter (default)**: 2–3 unique pathTrie paths
- **Without any edge filter**: 7 unique pathTrie paths

### Iteration-by-iteration edge progression (no filter)

- 45 edges on iteration 0 (cold cache)
- 40 edges on iterations 1–7 (warm)
- 54 edges on iterations 8–11 (poller teardown ran within iteration window)
- Flip-flops between 40 and 54 thereafter

### Varying edges (symbolized)

All 14 edges that toggle are in `GenericTimerPoller.__deallocating_deinit` and
`.deinit`. The 10 "first-iteration-only" edges are metadata accessors
(`Ma`, `Mr`) and lazy witness table accessors (`Wl`) for `UUID`, `Continuation`,
and `GenericTimerPoller` itself — one-shot cache-miss edges, not scheduling-sensitive.

### Conclusion

3 corpus entries is **expected** for this input shape. OS scheduling does
interleave the two lanes, but the edges visited are identical across
interleavings because:

1. Actor-isolated methods run atomically at edge level — no per-edge interleaving
2. Same call site produces the same PCs regardless of which lane invoked it
3. The only observed edge-set variation is in cleanup timing (whether deinit
   runs before the snapshot) and one-shot metadata init edges

To surface more paths, the test body needs **divergent control flow based on
input or state** (e.g., conditionally call different actor methods) rather
than same-call-site repetition.

## Filter decision — kept

Bare `TQ<digits>_` / `TY<digits>_` suffix filter is REQUIRED. Temporarily
removed during investigation; restoration was necessary because:

- **Level 1/2/3 determinism tests in CoverageDeterminismTest.swift** expect
  `unique == 1` under schedule control (same schedule bytes → same path).
- Without the filter, those tests report 50 unique paths in 50 runs — every
  run produces a different pathTrie even under deterministic scheduling.
- Reason: two concurrent continuations can be enqueued onto the scheduler in
  either order before the schedule bytes influence anything; the resulting
  "which TQ edge fires first" is scheduling-level noise that schedule control
  does not eliminate.

Decision: keep all existing filters (`Wl`, `Ma`, `Mr`, `TA`, `TR`, `WO*`,
`TATQ`/`TATY`/`TRTQ`/`TRTY`, bare `TQ<d>_`/`TY<d>_`, `vau`, `fA<d>_`).

Trade-off accepted: uncontrolled fuzz of simple actor ops sees fewer paths
than a naive reading of "concurrent interleaving" would suggest. That's not
a bug — it reflects the fact that actor-isolated code runs atomically at
edge level.

## Run Log

### R1: body alone (no fuzz engine)
25,000 iter/s direct invocation. H2 falsified — body is fast.

### R2: body through fuzz engine
- no-op: 99K iter/s
- single-lane actor: 49K iter/s
- TaskGroup + actor: 80K iter/s (with `.refuzzReplace`)
- TaskGroup + actor (auto): **4 replays** (regression mode)

### R3: path count (200 iter, direct, concurrent body)
- Full filter: 2 unique paths
- Filter minus bare TQ/TY: 2 unique paths
- No filter: 7 unique paths

### R4: varying edges (50 iter, direct, concurrent body, no filter)
- Union: 49 edges
- Intersection: 39 edges (same every run)
- Varying: 10 edges (metadata + witness + destructor)
