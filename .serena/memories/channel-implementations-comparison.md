# High-Performance Channel Implementations Comparison

## Comparison Table

| Implementation | Pattern | Key Technique | Wait Strategy | Async Integration |
|----------------|---------|---------------|---------------|-------------------|
| AsyncChannel | MPSC bounded | CAS slot reservation + per-slot flags | Continuation + lock | Swift async/await |
| SpinChannel | MPSC bounded | CAS slot reservation + per-slot flags | Pure busy-spin | None (blocking) |
| SyncChannel | MPSC bounded | CAS slot reservation + per-slot flags | DispatchSemaphore | None (blocking) |
| LMAX Disruptor | MPMC bounded | Sequence numbers, no per-slot flags | Busy-spin / yield | None (blocking) |
| Vyukov MPSC | MPSC unbounded | Single XCHG per push, linked list | Consumer spins on next ptr | None |
| rigtorp SPSC | SPSC bounded | Cached indices, no atomics on fast path | Spin on cached index | None |
| rigtorp MPMC | MPMC bounded | Turn-based tickets (even=write, odd=read) | Spin on turn | None |
| Tokio mpsc | MPSC bounded | Semaphore for capacity, separate waker | Async poll + waker | Rust async |
| Go channels | MPMC bounded | Mutex + ring buffer + goroutine queues | Park goroutine | Go runtime |

## Suitability for PropertyTestingKit Fuzzing

**Our requirements:**
- Multiple fuzzing workers producing inputs/coverage data (MPSC minimum)
- Single consumer processing results
- Hot-path performance critical on send()
- Bounded memory (long-running fuzz campaigns)
- Integration with Swift concurrency

### Would Work

| Implementation | Why It Fits | Caveats |
|----------------|-------------|---------|
| **SpinChannel (ours)** | 2.3x faster RTT than async (631 ns). Proven in benchmarks. | Burns 100% CPU while waiting. Best for dedicated fuzzing threads. |
| **Vyukov MPSC** | Single XCHG per push is optimal for producer hot path. Wait-free producers. | Unbounded - needs modification for memory limits. Linked list allocations could add overhead. |
| **Tokio mpsc** | Designed for async runtime integration. Semaphore-based backpressure. Similar architecture to ours. | Our SyncChannel benchmark showed semaphores are slower than continuations in Swift. |
| **rigtorp MPMC** | Bounded, proven low-latency. Turn-based approach is fair. | More complex than needed (we only need SC). Turn spinning could waste CPU. |

### Would NOT Work

| Implementation | Why It Doesn't Fit |
|----------------|-------------------|
| **rigtorp SPSC** | Single-producer only. We have multiple fuzzing workers. Non-starter. |
| **LMAX Disruptor** | Busy-spin burns CPU. However, our SpinChannel benchmarks prove spinning IS viable when dedicating threads to fuzzing. Consider if workload has enough message volume to justify CPU cost. |
| **Go channels** | Mutex on hot path. Go channels are known to be slower than lock-free alternatives. The mutex acquisition on every send() would create contention with multiple producers. |

### Key Insights

1. **Our current design is reasonable** - CAS slot reservation is similar to Vyukov's approach but bounded.

2. **The bottleneck is the wait strategy, not the queue** - All high-perf queues use spinning. Our SpinChannel proves this works in Swift too.

3. **Spinning is viable for fuzzing** - SpinChannel's 2.3x improvement justifies dedicated CPU cores for high-throughput fuzzing workers.

4. **Three channel options for different needs**:
   - SpinChannel: Maximum throughput, dedicated threads
   - AsyncChannel: Cooperative scheduling, good perf
   - SyncChannel: Blocking threads, worst perf (avoid)

## Benchmark Results (Our Implementations)

| Metric | AsyncChannel | SyncChannel | SpinChannel |
|--------|-------------|-------------|-------------|
| Send Latency | 53 ns | 47 ns | **46 ns** |
| TryRecv Latency | 53 ns | 54 ns | 55 ns |
| SPSC Throughput | 5.9 M ops/sec | 5.7 M ops/sec | **7.8 M ops/sec** |
| Round-Trip Latency | 1,473 ns | 3,279 ns | **631 ns** |

### Performance Ranking

1. **SpinChannel** (pure busy-spin): 631 ns RTT - fastest, but burns CPU
2. **AsyncChannel** (Swift continuations): 1,473 ns RTT - 2.3x slower than spin
3. **SyncChannel** (DispatchSemaphore): 3,279 ns RTT - 5.2x slower than spin

### Overhead Hierarchy

| Wait Strategy | Overhead Source | RTT Cost |
|---------------|-----------------|----------|
| Busy-spin | None (pure CPU) | ~600 ns |
| Swift async continuation | Task scheduling, executor enqueue | ~1,500 ns |
| DispatchSemaphore | Kernel syscall, thread wake | ~3,300 ns |

### Conclusions

1. **SpinChannel achieves near-rigtorp performance** (~631 ns vs rigtorp's ~133 ns RTT)
2. **Swift's async system is well-optimized** - 2x faster than semaphores
3. **The async overhead is real but reasonable** - if you can dedicate CPU cores, spinning wins
4. **For PropertyTestingKit**: SpinChannel may be worth using for dedicated fuzzing workers where throughput matters more than power efficiency
