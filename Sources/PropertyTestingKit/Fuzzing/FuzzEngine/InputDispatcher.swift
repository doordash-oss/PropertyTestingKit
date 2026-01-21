//
//  InputDispatcher.swift
//  PropertyTestingKit
//
//  Distributes test inputs to workers using round-robin scheduling.
//  Each worker has its own SPSC channel for receiving inputs.
//

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
    private let channels: [KFIFOQueue<(repeat each Input)>]
    private var nextWorker: Int = 0

    /// Creates a dispatcher with the specified number of worker channels.
    ///
    /// - Parameters:
    ///   - workerCount: Number of workers (and channels) to create.
    ///   - channelCapacity: Capacity for each worker's channel. Default 256.
    ///     Higher k reduces CAS contention under heavy load but increases scan time on sparse queues.
    init(workerCount: Int, channelCapacity: Int = 256) {
        precondition(workerCount > 0, "Must have at least one worker")

        var channels: [KFIFOQueue<(repeat each Input)>] = []
        channels.reserveCapacity(workerCount)
        for _ in 0..<workerCount {
            channels.append(KFIFOQueue(k: channelCapacity))
        }
        self.channels = channels
    }

    /// Number of workers/channels.
    var workerCount: Int {
        channels.count
    }

    /// Returns the channel for the specified worker.
    /// Workers should only access their own channel.
    func channel(for workerIndex: Int) -> KFIFOQueue<(repeat each Input)> {
        channels[workerIndex]
    }

    /// Pushes a single input, distributing to the next worker round-robin.
    func push(_ input: repeat each Input) {
        let workerIndex = nextWorkerIndex()
        channels[workerIndex].enqueue((repeat each input))
    }

    /// Pushes multiple inputs, distributing them round-robin across workers.
    func push(contentsOf inputs: [(repeat each Input)]) {
        for input in inputs {
            let workerIndex = nextWorkerIndex()
            channels[workerIndex].enqueue(input)
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

    /// Gets the next worker index using round-robin.
    private func nextWorkerIndex() -> Int {
        let index = nextWorker
        nextWorker = (nextWorker + 1) % channels.count
        return index
    }
}
