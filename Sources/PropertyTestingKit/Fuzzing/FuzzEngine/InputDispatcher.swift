//
//  InputDispatcher.swift
//  PropertyTestingKit
//
//  Distributes test inputs to workers using round-robin scheduling.
//  Each worker has its own SPSC channel for receiving inputs.
//

import Atomics
import ConcurrentQueues

/// Distributes test inputs to workers using round-robin scheduling.
///
/// Each worker has a dedicated SPSC channel. When inputs are pushed,
/// they are distributed round-robin across all worker channels.
/// Workers receive their individual channel and pull from it directly.
///
/// ## Usage
///
/// ```swift
/// let dispatcher = InputDispatcher<Int>(workerCount: 4)
///
/// // Push inputs (distributed round-robin)
/// dispatcher.push(42)
/// dispatcher.push(contentsOf: [1, 2, 3, 4])
///
/// // Get channel for a worker (workers only see their own channel)
/// let workerChannel = dispatcher.channel(for: 0)
/// if let input = workerChannel.tryRecv() {
///     process(input)
/// }
/// ```
final class InputDispatcher<each Input: Sendable>: @unchecked Sendable {
    private let channels: [RCQSQueue<(repeat each Input)>]
    private let nextWorker: ManagedAtomic<Int>

    /// Creates a dispatcher with the specified number of worker channels.
    ///
    /// - Parameters:
    ///   - workerCount: Number of workers (and channels) to create.
    ///   - channelCapacity: Capacity for each worker's channel. Default 256.
    init(workerCount: Int, channelCapacity: Int = 256) {
        precondition(workerCount > 0, "Must have at least one worker")

        var channels: [RCQSQueue<(repeat each Input)>] = []
        channels.reserveCapacity(workerCount)
        for _ in 0..<workerCount {
            channels.append(RCQSQueue(capacity: channelCapacity))
        }
        self.channels = channels
        self.nextWorker = ManagedAtomic(0)
    }

    /// Number of workers/channels.
    var workerCount: Int {
        channels.count
    }

    /// Returns the channel for the specified worker.
    /// Workers should only access their own channel.
    func channel(for workerIndex: Int) -> RCQSQueue<(repeat each Input)> {
        channels[workerIndex]
    }

    /// Pushes a single input, distributing to the next worker round-robin.
    func push(_ input: repeat each Input) {
        let workerIndex = nextWorkerIndex()
        channels[workerIndex].send((repeat each input))
    }

    /// Pushes multiple inputs, distributing them round-robin across workers.
    func push(contentsOf inputs: [(repeat each Input)]) {
        for input in inputs {
            let workerIndex = nextWorkerIndex()
            channels[workerIndex].send(input)
        }
    }

    /// Closes all worker channels.
    func closeAll() {
        for channel in channels {
            channel.close()
        }
    }

    /// Returns the total number of dropped inputs across all channels.
    /// Always returns 0 since channels no longer drop messages.
    var totalDroppedCount: UInt64 {
        0
    }

    /// Gets the next worker index using atomic round-robin.
    private func nextWorkerIndex() -> Int {
        let count = channels.count
        // Atomically increment and wrap around
        while true {
            let current = nextWorker.load(ordering: .relaxed)
            let next = (current + 1) % count
            let (exchanged, _) = nextWorker.compareExchange(
                expected: current,
                desired: next,
                successOrdering: .relaxed,
                failureOrdering: .relaxed
            )
            if exchanged {
                return current
            }
            // CAS failed, retry
        }
    }
}
