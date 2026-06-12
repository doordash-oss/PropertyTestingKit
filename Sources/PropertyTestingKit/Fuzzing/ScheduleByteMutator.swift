/// Mutator for schedule bytes — the byte sequence that controls task
/// interleaving order during schedule-fuzzed test execution.
///
/// Schedule bytes are permutation selectors: `byte % pendingCount` picks
/// which pending job runs next. Mutations that preserve byte count are
/// most useful since length changes don't meaningfully expand the schedule
/// space (the drain loop falls back to index 0 when bytes are exhausted).
///
/// Mutation strategies (AFL-inspired, length-preserving), ONE picked per call:
/// - Bit flip: flip 1-4 random bits in a random byte
/// - Byte replace: replace 1-2 bytes with random values
/// - Arithmetic: increment/decrement a random byte
/// - Block swap: swap two 2-4 byte blocks (reorders scheduling decisions)
enum ScheduleByteMutator {
    static let defaultLength = 64

    static func generate(using rng: inout FastRNG) -> [UInt8] {
        (0..<defaultLength).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    static func mutate(_ bytes: [UInt8], using rng: inout FastRNG) -> [UInt8] {
        guard !bytes.isEmpty else { return bytes }

        switch Int.random(in: 0..<4, using: &rng) {
        case 0:
            // Bit flip: flip 1-4 bits in a random byte
            var bitFlip = bytes
            let flipIdx = Int.random(in: 0..<bytes.count, using: &rng)
            let flipCount = Int.random(in: 1...4, using: &rng)
            for _ in 0..<flipCount {
                bitFlip[flipIdx] ^= 1 << UInt8.random(in: 0...7, using: &rng)
            }
            return bitFlip

        case 1:
            // Byte replace: replace 1-2 random bytes
            var byteReplace = bytes
            let replaceCount = Int.random(in: 1...min(2, bytes.count), using: &rng)
            for _ in 0..<replaceCount {
                let idx = Int.random(in: 0..<bytes.count, using: &rng)
                byteReplace[idx] = UInt8.random(in: 0...255, using: &rng)
            }
            return byteReplace

        case 2:
            // Arithmetic: increment or decrement a random byte
            var arith = bytes
            let arithIdx = Int.random(in: 0..<bytes.count, using: &rng)
            if Bool.random(using: &rng) {
                arith[arithIdx] &+= UInt8.random(in: 1...16, using: &rng)
            } else {
                arith[arithIdx] &-= UInt8.random(in: 1...16, using: &rng)
            }
            return arith

        default:
            // Block swap: swap two small blocks to reorder scheduling decisions
            guard bytes.count >= 4 else { return mutate(bytes, using: &rng) }
            let blockSize = Int.random(in: 2...min(4, bytes.count / 2), using: &rng)
            let maxStart = bytes.count - blockSize
            // Re-roll BOTH endpoints until the blocks are non-overlapping. Only
            // re-rolling `b` can spin forever (e.g. count == 4, blockSize == 2,
            // a == 1 leaves no valid `b`), so vary `a` too and cap attempts.
            var a = Int.random(in: 0...maxStart, using: &rng)
            var b = Int.random(in: 0...maxStart, using: &rng)
            var attempts = 0
            while abs(a - b) < blockSize && attempts < 16 {
                a = Int.random(in: 0...maxStart, using: &rng)
                b = Int.random(in: 0...maxStart, using: &rng)
                attempts += 1
            }
            guard abs(a - b) >= blockSize else { return mutate(bytes, using: &rng) }
            var blockSwap = bytes
            for i in 0..<blockSize {
                blockSwap.swapAt(a + i, b + i)
            }
            return blockSwap
        }
    }
}
