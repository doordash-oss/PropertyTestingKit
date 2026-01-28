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

/// Synchronous plugin processor that processes events inline without channels.
/// Processes plugins sequentially and executes actions immediately.
struct SyncPluginProcessor: Sendable {
    let plugins: [any FuzzPlugin]

    func process<each Input: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        event: consuming PluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) async {
        guard !plugins.isEmpty else { return }

        // Process all plugins except the last with copies
        if plugins.count > 1 {
            for plugin in plugins.dropLast() {
                do {
                    let actions = try await plugin.handle(event: copy event)
                    for action in actions {
                        execute(action)
                    }
                } catch {
                    // Plugin errors are non-fatal
                }
            }
        }

        // Process the last plugin with consume (move semantics)
        if let lastPlugin = plugins.last {
            do {
                let actions = try await lastPlugin.handle(event: consume event)
                for action in actions {
                    execute(action)
                }
            } catch {
                // Plugin errors are non-fatal
            }
        }
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
                    await processEvent(event)
                } else {
                    // Yield when empty to avoid busy-waiting
                    await Task.yield()
                }
            }
            // Drain any remaining events
            while let event = eventChannel.dequeue() {
                await processEvent(event)
            }
        }
    }

    func awaitCompletion() async {
        await processorTask?.value
    }

    /// Process an event through all plugins, using copy for all-but-last and consume for last.
    private func processEvent(_ event: consuming PluginEvent<repeat each Input>) async {
        guard !plugins.isEmpty else { return }

        // Process all plugins except the last with copies
        if plugins.count > 1 {
            for plugin in plugins.dropLast() {
                do {
                    let actions = try await plugin.handle(event: copy event)
                    for action in actions {
                        actionChannel.enqueue(action)
                    }
                } catch {
                    // Plugin errors are non-fatal - just skip this plugin's actions
                }
            }
        }

        // Process the last plugin with consume (move semantics)
        if let lastPlugin = plugins.last {
            do {
                let actions = try await lastPlugin.handle(event: consume event)
                for action in actions {
                    actionChannel.enqueue(action)
                }
            } catch {
                // Plugin errors are non-fatal
            }
        }
    }
}
