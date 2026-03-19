//
// GenericTimerPoller.swift
// Copyright © 2026 DoorDash. All rights reserved.
//

import Clocks
import Combine
import Dependencies
import Foundation

/// A reusable timer-based poller..
///
/// Usage:
/// ```swift
/// let poller = GenericTimerPoller()
/// let cancellable = poller.subscribe { /* Timed activity here */ } // retain the cancellable while you need updates
/// poller.startPolling()
/// // ... later
/// cancellable.cancel() // removes one subscriber; timer stops when the last subscriber is gone
/// ```
public actor GenericTimerPoller {
    /// Handler that gets executed each time the timer fires.
    public typealias PollHandler = () async throws -> Void

    /// Used for testing, emits when handlers emit
    public nonisolated let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    /// Clock used for sleeping between polls (injectable for tests)
    @Dependency(\.continuousClock) var clock

    // Polling intervals
    var defaultInterval: Duration
    var intervalOverride: Duration?

    // Combine subscription to the underlying timer
    var pollingTask: Task<Void, Error>?

    /// The closure to execute on every tick
    var handlers: [UUID: PollHandler]

    /// Optional callback invoked on deallocation (for testing lifecycle).
    private var onDeinitCallback: (@Sendable () -> Void)?

    deinit {
        // Only cancel the task — this is safe from any thread.
        // Do not call actor-isolated methods (stopPolling) from deinit.
        continuation.finish()
        pollingTask?.cancel()
        onDeinitCallback?()
    }

    /// Registers a callback that fires when this actor is deallocated.
    public func onDeinit(_ callback: @escaping @Sendable () -> Void) {
        onDeinitCallback = callback
    }

    // Current effective interval
    var effectiveInterval: Duration { intervalOverride ?? defaultInterval }

    private let line: Int
    private let function: String
    private let file: String

    // MARK: - Init

    /// - Parameters:
    ///   - defaultInterval: Base interval (in seconds) when no override is set.
    public init(defaultInterval: Duration = .seconds(60), line: Int = #line, function: String = #function, file: String = #filePath) {
        self.line = line
        self.function = function
        self.file = file
        self.defaultInterval = defaultInterval
        self.handlers = [:]
        (self.stream, self.continuation) = AsyncStream<Void>.makeStream()
    }

    // MARK: - Public API

    /// Starts (or restarts) the timer-driven polling
    public func startPolling() {
        configureTimer(initialCall: true)
    }

    /// Registers the caller as a subscriber.
    ///
    /// The returned `AnyCancellable` automatically removes the caller when it is deallocated or cancelled.
    @discardableResult
    public func subscribe(handler: @escaping PollHandler) -> AnyCancellable {
        let id = UUID()
        handlers[id] = handler

        // Each caller manages its own cancellable; when it cancels we decrease the count.
        // Must dispatch through the actor — AnyCancellable's closure runs on arbitrary threads.
        return AnyCancellable { [weak self] in
            guard let self else { return }
            Task { await self.unsubscribe(id) }
        }
    }

    func unsubscribe(_ id: UUID) {
        handlers[id] = nil
        if handlers.isEmpty {
            stopPolling()
        }
    }

    /// Temporarily stops the timer but keeps subscriber bookkeeping intact.
    public func pausePolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Resumes polling if at least one subscriber is still registered.
    /// Triggers `handler` immediately
    public func resumePolling() {
        guard handlers.count > 0, pollingTask == nil else { return }
        configureTimer(initialCall: false)
    }

    /// Removes all subscribers and tears down the timer.
    public func stopPolling() {
        handlers = [:]
        continuation.finish()
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Updates the timer interval. Passing `nil` reverts to the default interval.
    /// If polling is active, the timer restarts immediately with the new cadence.
    /// Waits for the new interval to pass before triggering `handler` the first time.
    /// - Parameter newInterval: New interval in seconds, or `nil` to clear the override.
    public func updateInterval(_ newInterval: Duration?) {
        intervalOverride = newInterval
        if pollingTask != nil {
            configureTimer(initialCall: false)
        }
    }

    // MARK: - Private helpers

    /// - Parameter initialCall: Trigger the callback on the first loop.
    private func configureTimer(initialCall: Bool) {
        // Cancel existing task before starting a new one
        pollingTask?.cancel()

        let interval = effectiveInterval

        pollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            // We want to trigger the handler immediately when we start polling
            if initialCall {
                try await callHandler()
            }

            while !Task.isCancelled {
                // Sleep for the configured interval using the injected clock
                try await clock.sleep(for: interval)

                try await callHandler()
            }
        }
    }

    private func callHandler() async throws {
        for handler in handlers.values {
            try await handler()
        }
        continuation.yield()
    }
}
