# AFL Havoc Mode

**Source**: AFL Technical Whitepaper, AFL++ Documentation
**URL**: https://lcamtuf.coredump.cx/afl/technical_details.txt

---

## Summary

Havoc mode is AFL's aggressive, non-deterministic mutation stage that applies multiple stacked random mutations to inputs. It kicks in after deterministic stages exhaust their potential, representing a shift from systematic exploration to chaotic search.

---

## AFL's Mutation Pipeline

AFL processes each corpus entry through stages in order:

1. **Deterministic stages** (systematic, exhaustive):
   - Bit flips (1, 2, 4 bits at each position)
   - Byte flips (1, 2, 4 bytes)
   - Arithmetic (add/subtract small integers)
   - Interesting values (0, 1, -1, MAX_INT, etc.)
   - Dictionary insertion

2. **Havoc stage** (random, stacked):
   - Apply 2^(1 to 7) random mutations per input
   - Each mutation randomly chosen from ~15 operators
   - Mutations stack on each other

3. **Splice stage** (recombination):
   - Combine parts of different corpus entries

---

## Havoc Mutation Operators

During havoc, AFL randomly selects from:

| Operator | Description |
|----------|-------------|
| Bit flip | Flip random bit |
| Byte set | Set random byte to interesting value |
| Byte subtract | Subtract small random value from byte |
| Byte add | Add small random value to byte |
| Word subtract (BE/LE) | Subtract from 16-bit word |
| Word add (BE/LE) | Add to 16-bit word |
| Dword subtract (BE/LE) | Subtract from 32-bit dword |
| Dword add (BE/LE) | Add to 32-bit dword |
| Byte randomize | Set random byte to random value |
| Block delete | Remove random chunk |
| Block insert | Clone or insert random chunk |
| Block overwrite | Overwrite with random or cloned data |
| Dictionary insert | Insert dictionary token |

---

## Key Characteristics

**Stacking**: Unlike deterministic stages (one mutation per test), havoc applies multiple mutations. The "stacking factor" (how many mutations per test) is randomized:
- Minimum: 2 mutations
- Maximum: 128 mutations (2^7)
- Distribution favors lower counts

**Randomness**: Every aspect is random:
- Which operator
- Where in the input
- What value (for value-based ops)
- How many mutations to stack

**Duration**: Havoc runs much longer than deterministic stages. AFL allocates "energy" (iteration budget) to each corpus entry, and most of that energy goes to havoc.

---

## Why Havoc Works

1. **Escapes local optima**: Deterministic mutations are small steps. Havoc's stacking can make large jumps in the input space.

2. **Discovers emergent behavior**: Multiple mutations can interact to trigger bugs that no single mutation would find.

3. **Compensates for coverage blindness**: When coverage feedback can't guide toward a target (magic bytes, checksums), random exploration becomes necessary.

4. **Efficient for large inputs**: For a 10KB input, exhaustive bit-flipping is 80,000 tests. Havoc samples the space stochastically.

---

## Applicability to PropertyTestingKit

**Current state**: PropertyTestingKit applies one mutation per test, similar to AFL's deterministic stages. There's no "havoc equivalent" that stacks multiple mutations.

**Potential enhancement**:

```swift
// Conceptual havoc mode for PropertyTestingKit
func havocMutate<T: Fuzzable>(_ value: T, stackingFactor: Int) -> T {
    var result = value
    let mutationCount = Int.random(in: 2...stackingFactor)

    for _ in 0..<mutationCount {
        // Apply random mutation from available strategies
        if let mutated = result.mutate().randomElement() {
            result = mutated
        }
    }
    return result
}
```

**When to use**:
- After simple mutations stop finding coverage
- When plateau is detected
- For inputs with checksums or magic values

**Your original idea** (exponential mutations as plateau approaches) is related but different:
- Havoc: stack mutations for exploration depth
- Your idea: increase stacking as discovery rate drops (adaptive havoc)

The combination could be powerful: start with single mutations, progressively increase stacking factor as plateau detection signals diminishing returns.

---

## References

- AFL Technical Whitepaper: https://lcamtuf.coredump.cx/afl/technical_details.txt
- AFL++ Havoc Implementation: https://github.com/AFLplusplus/AFLplusplus/blob/stable/src/afl-fuzz-one.c
- "Fuzzing: Art, Science, and Engineering" survey: https://arxiv.org/abs/1812.00140
