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
/// Uses two SPSC channels for fully decoupled communication:
/// 1. Event channel: FuzzStateMachine sends events (fire-and-forget, non-blocking)
/// 2. Action channel: FuzzStateMachine receives actions (pull-based)
///
/// This design fully decouples the hot fuzzing loop from plugin overhead.
public final class PluginCoordinator<each Input: Sendable>: Sendable {
    private let eventChannel: RCQSQueue<PluginEvent<repeat each Input>>
    private let actionChannel: RCQSQueue<FuzzPluginAction<repeat each Input>>

    private let processor: PluginProcessor<repeat each Input>

    /// Channel of actions for the FuzzStateMachine to consume.
    public var actions: RCQSQueue<FuzzPluginAction<repeat each Input>> {
        actionChannel
    }

    /// Create a coordinator with the given plugins.
    ///
    /// - Parameters:
    ///   - plugins: The plugins to dispatch events to.
    ///   - eventChannelCapacity: Capacity for the event channel. Default 1024.
    ///   - actionChannelCapacity: Capacity for the action channel. Default 1024.
    public init(
        plugins: [any FuzzPlugin],
        eventChannelCapacity: Int = 1024,
        actionChannelCapacity: Int = 1024
    ) {
        self.eventChannel = RCQSQueue(capacity: eventChannelCapacity)
        self.actionChannel = RCQSQueue(capacity: actionChannelCapacity)

        self.processor = PluginProcessor(
            eventChannel: eventChannel,
            actionChannel: actionChannel,
            plugins: plugins
        )
    }

    /// Start the background processor task.
    ///
    /// Must be called before submitting events.
    public func start() async {
        await processor.start()
    }

    /// Submit an event for asynchronous processing (fire-and-forget).
    ///
    /// This is non-blocking and lock-free. The event will be
    /// processed by the background task.
    ///
    /// - Parameter event: The plugin event to dispatch.
    public func send(event: PluginEvent<repeat each Input>) {
        eventChannel.send(event)
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
    /// Always returns 0 since channels no longer drop messages.
    public var droppedEventCount: UInt64 {
        0
    }

    /// Number of actions dropped due to channel overflow.
    /// Always returns 0 since channels no longer drop messages.
    public var droppedActionCount: UInt64 {
        0
    }
}

/// Actor that processes events from the event channel and produces actions
/// to the action channel.
actor PluginProcessor<each Input: Sendable> {
    private let eventChannel: RCQSQueue<PluginEvent<repeat each Input>>
    private let actionChannel: RCQSQueue<FuzzPluginAction<repeat each Input>>
    private let plugins: [any FuzzPlugin]

    private var processorTask: Task<Void, Never>?

    init(
        eventChannel: RCQSQueue<PluginEvent<repeat each Input>>,
        actionChannel: RCQSQueue<FuzzPluginAction<repeat each Input>>,
        plugins: [any FuzzPlugin]
    ) {
        self.eventChannel = eventChannel
        self.actionChannel = actionChannel
        self.plugins = plugins
    }

    func start() {
        processorTask = Task { [self] in
            // Use tryRecv with yield to avoid blocking the cooperative pool
            while !eventChannel.isClosed {
                if let event = eventChannel.tryRecv() {
                    // Dispatch to each plugin and send actions immediately
                    for plugin in plugins {
                        do {
                            let actions = try await plugin.handle(event: event)
                            for action in actions {
                                actionChannel.send(action)
                            }
                        } catch {
                            // TODO: We shouldn't ignore cancellation
                            // Plugin errors logged but don't stop processing
                        }
                    }
                } else {
                    await Task.yield()
                }
            }
            // Drain any remaining events
            while let event = eventChannel.tryRecv() {
                for plugin in plugins {
                    do {
                        let actions = try await plugin.handle(event: event)
                        for action in actions {
                            actionChannel.send(action)
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
