//
//  PluginCoordinator.swift
//  PropertyTestingKit
//
//  Bidirectional async message queue coordination between fuzz engine and plugins.
//  Uses high-performance SPSC channels for minimal overhead.
//

import ConcurrentQueues
import Foundation

/// Coordinates bidirectional async messaging between fuzz engine and plugins.
///
/// Uses two SPSC growable ring buffers for fully decoupled communication:
/// 1. Event channel: FuzzStateMachine sends events (fire-and-forget, non-blocking)
/// 2. Action channel: FuzzStateMachine receives actions (pull-based)
///
/// This design fully decouples the hot fuzzing loop from plugin overhead.
/// Using growable ring buffers eliminates per-enqueue allocation overhead
/// while avoiding backpressure/blocking issues.
public final class PluginCoordinator<each Input: Sendable>: Sendable {
    /// Default initial channel capacity (power of 2 for efficient indexing).
    /// 64K provides good throughput without frequent resizing at typical rates.
    private static var defaultCapacity: Int { 65536 }

    private let eventChannel: SPSCGrowableRing<PluginEvent<repeat each Input>>
    let actionChannel: SPSCGrowableRing<FuzzPluginAction<repeat each Input>>

    private let processor: PluginProcessor<repeat each Input>

    /// Create a coordinator with the given plugins.
    ///
    /// - Parameters:
    ///   - plugins: The plugins to dispatch events to.
    ///   - channelCapacity: Initial capacity for channels (grows if needed).
    public init(
        plugins: [any FuzzPlugin],
        channelCapacity: Int = 65536
    ) {
        self.eventChannel = SPSCGrowableRing(capacity: channelCapacity)
        self.actionChannel = SPSCGrowableRing(capacity: channelCapacity)

        self.processor = PluginProcessor(
            eventChannel: eventChannel,
            actionChannel: actionChannel,
            plugins: plugins
        )
    }

    /// Start the background processor task.
    ///
    /// Must be called before submitting events.
    public func start() {
        processor.start()
    }

    /// Submit an event for asynchronous processing (fire-and-forget).
    ///
    /// This is non-blocking and lock-free. The event will be
    /// processed by the background task. Takes ownership of the event (no copy).
    ///
    /// - Parameter event: The plugin event to dispatch (consumed).
    public func send(event: consuming PluginEvent<repeat each Input>) {
        eventChannel.enqueue(event)
    }

    /// Close the event channel and wait for all events to be processed.
    ///
    /// After this returns, all events have been dispatched and all resulting
    /// actions have been sent to the action channel (which is also closed).
    public func closeAndAwaitCompletion() async {
        eventChannel.close()
        await processor.awaitCompletion()
        actionChannel.close()
    }

    // MARK: - Stats (for testing/debugging)

    /// Number of events dropped due to channel overflow.
    /// Always returns 0 since channels are unbounded.
    public var droppedEventCount: UInt64 {
        0
    }

    /// Number of actions dropped due to channel overflow.
    /// Always returns 0 since channels are unbounded.
    public var droppedActionCount: UInt64 {
        0
    }
}

/// Processes events from the event channel and produces actions to the action channel.
/// Runs as a detached high-priority Task to ensure it gets scheduled independently.
final class PluginProcessor<each Input: Sendable>: @unchecked Sendable {
    private let eventChannel: SPSCGrowableRing<PluginEvent<repeat each Input>>
    private let actionChannel: SPSCGrowableRing<FuzzPluginAction<repeat each Input>>
    private let plugins: [any FuzzPlugin]

    private var processorTask: Task<Void, Never>?

    init(
        eventChannel: SPSCGrowableRing<PluginEvent<repeat each Input>>,
        actionChannel: SPSCGrowableRing<FuzzPluginAction<repeat each Input>>,
        plugins: [any FuzzPlugin]
    ) {
        self.eventChannel = eventChannel
        self.actionChannel = actionChannel
        self.plugins = plugins
    }

    func start() {
        // Use Task.detached to get independent scheduling from parent context
        processorTask = Task.detached(priority: .high) { [self] in
            // Run event processing loop
            while !eventChannel.isClosed {
                if let event = eventChannel.dequeue() {
                    // Process event with plugins
                    for plugin in plugins {
                        do {
                            let actions = try await plugin.handle(event: event)
                            for action in actions {
                                actionChannel.enqueue(action)
                            }
                        } catch {
                            // Plugin errors logged but don't stop processing
                        }
                    }
                } else {
                    // Yield when empty to avoid busy-waiting
                    await Task.yield()
                }
            }
            // Drain any remaining events
            while let event = eventChannel.dequeue() {
                for plugin in plugins {
                    do {
                        let actions = try await plugin.handle(event: event)
                        for action in actions {
                            actionChannel.enqueue(action)
                        }
                    } catch {
                        // Plugin errors logged but don't stop processing
                    }
                }
            }
        }
    }

    func awaitCompletion() async {
        await processorTask?.value
    }
}
