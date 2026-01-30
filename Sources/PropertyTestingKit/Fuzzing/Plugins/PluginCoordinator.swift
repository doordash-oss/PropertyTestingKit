//
//  PluginCoordinator.swift
//  PropertyTestingKit
//
//  Bidirectional async message queue coordination between fuzz engine and plugins.
//  Uses high-performance SPSC channels for minimal overhead.
//

import ConcurrentQueues
import Foundation

///// Coordinates bidirectional async messaging between fuzz engine and plugins.
/////
///// Uses two SPSC growable ring buffers for fully decoupled communication:
///// 1. Event channel: FuzzStateMachine sends events (fire-and-forget, non-blocking)
///// 2. Action channel: FuzzStateMachine receives actions (pull-based)
/////
///// This design fully decouples the hot fuzzing loop from plugin overhead.
///// Using growable ring buffers eliminates per-enqueue allocation overhead
///// while avoiding backpressure/blocking issues.
//public final class PluginCoordinator<each Input: Sendable>: Sendable {
//    /// Default initial channel capacity (power of 2 for efficient indexing).
//    /// 64K provides good throughput without frequent resizing at typical rates.
//    private static var defaultCapacity: Int { 65536 }
//
//    private let eventChannel: SPSCGrowableRing<PluginEvent<repeat each Input>>
//    let actionChannel: SPSCGrowableRing<FuzzPluginAction<repeat each Input>>
//
//    private let processor: PluginProcessor<repeat each Input>
//
//    /// Create a coordinator with the given plugins.
//    ///
//    /// - Parameters:
//    ///   - plugins: The plugins to dispatch events to.
//    ///   - channelCapacity: Initial capacity for channels (grows if needed).
//    public init(
//        plugins: [any FuzzPlugin],
//        channelCapacity: Int = 65536
//    ) {
//        self.eventChannel = SPSCGrowableRing(capacity: channelCapacity)
//        self.actionChannel = SPSCGrowableRing(capacity: channelCapacity)
//
//        self.processor = PluginProcessor(
//            eventChannel: eventChannel,
//            actionChannel: actionChannel,
//            plugins: plugins
//        )
//    }
//
//    /// Start the background processor task.
//    ///
//    /// Must be called before submitting events.
//    public func start() {
//        processor.start()
//    }
//
//    /// Submit an event for asynchronous processing (fire-and-forget).
//    ///
//    /// This is non-blocking and lock-free. The event will be
//    /// processed by the background task. Takes ownership of the event (no copy).
//    ///
//    /// - Parameter event: The plugin event to dispatch (consumed).
//    public func send(event: consuming PluginEvent<repeat each Input>) {
//        eventChannel.enqueue(event)
//    }
//
//    /// Close the event channel and wait for all events to be processed.
//    ///
//    /// After this returns, all events have been dispatched and all resulting
//    /// actions have been sent to the action channel (which is also closed).
//    public func closeAndAwaitCompletion() async {
//        eventChannel.close()
//        await processor.awaitCompletion()
//        actionChannel.close()
//    }
//
//    // MARK: - Stats (for testing/debugging)
//
//    /// Number of events dropped due to channel overflow.
//    /// Always returns 0 since channels are unbounded.
//    public var droppedEventCount: UInt64 {
//        0
//    }
//
//    /// Number of actions dropped due to channel overflow.
//    /// Always returns 0 since channels are unbounded.
//    public var droppedActionCount: UInt64 {
//        0
//    }
//}

/// Synchronous plugin processor that processes events inline without channels.
/// Generic over plugin types to enable monomorphization and eliminate protocol witness overhead.
@usableFromInline
struct SyncPluginProcessor<each Plugin: FuzzPlugin>: Sendable {
    @usableFromInline
    let plugins: (repeat each Plugin)

    @usableFromInline
    init(plugins: (repeat each Plugin)) {
        self.plugins = plugins
    }

    /// Process a synchronous event (iteration) - hot path, fully sync.
    @inlinable
    func processSync<each Input: Sendable>(
        event: consuming SyncPluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) {
        // Process each plugin synchronously
        for plugin in repeat each plugins {
            let actions = plugin.handle(event: copy event)
            for action in actions {
                execute(action)
            }
        }
        _ = consume event
    }

    /// Process an asynchronous event (start/end/failureFound) - cold path, async OK.
    @inlinable
    func processAsync<each Input: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        event: consuming AsyncPluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) async {
        // Process each plugin asynchronously
        for plugin in repeat each plugins {
            do {
                let actions = try await plugin.handleAsync(event: copy event)
                for action in actions {
                    execute(action)
                }
            } catch {
                // Plugin errors are non-fatal
            }
        }
        // Consume the event to satisfy ownership
        _ = consume event
    }
}
