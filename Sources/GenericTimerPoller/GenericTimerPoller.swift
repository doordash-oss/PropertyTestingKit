//
// GenericTimerPoller.swift
// Copyright © 2026 DoorDash. All rights reserved.
//

import Clocks
import Combine
import Dependencies
import Foundation
import os

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
    private nonisolated let continuation: AsyncStream<Void>.Continuation

    /// Clock used for sleeping between polls (injectable for tests)
    @Dependency(\.continuousClock) var clock

    // Polling intervals
    var defaultInterval: Duration
    var intervalOverride: Duration?

    /// Thread-safe shared state. Protected by OSAllocatedUnfairLock so that
    /// AnyCancellable's synchronous cancel closure can remove handlers and
    /// cancel the polling task without actor isolation.
    private nonisolated let _state = OSAllocatedUnfairLock(initialState: PollerState())

    /// Optional callback invoked on deallocation (for testing lifecycle).
    private var onDeinitCallback: (@Sendable () -> Void)?

    deinit {
        let task = _state.withLock { state in
            state.handlers = [:]
            let task = state.pollingTask
            state.pollingTask = nil
            return task
        }
        continuation.finish()
        task?.cancel()
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
    /// Cancellation is fully synchronous — the handler is removed and, if this was the last subscriber,
    /// the polling task is cancelled before `.cancel()` returns.
    @discardableResult
    public func subscribe(handler: @escaping PollHandler) -> AnyCancellable {
        let id = UUID()
        _state.withLock { $0.handlers[id] = handler }

        return AnyCancellable { [weak self] in
            guard let self else { return }
            let task = self._state.withLock { state -> Task<Void, Error>? in
                state.handlers[id] = nil
                if state.handlers.isEmpty {
                    let task = state.pollingTask
                    state.pollingTask = nil
                    return task
                }
                return nil
            }
            if let task {
                self.continuation.finish()
                task.cancel()
            }
        }
    }

    /// Temporarily stops the timer but keeps subscriber bookkeeping intact.
    public func pausePolling() {
        let task = _state.withLock { state in
            let task = state.pollingTask
            state.pollingTask = nil
            return task
        }
        task?.cancel()
    }

    /// Resumes polling if at least one subscriber is still registered.
    /// Triggers `handler` immediately
    public func resumePolling() {
        let (count, hasTask) = _state.withLock { ($0.handlers.count, $0.pollingTask != nil) }
        guard count > 0, !hasTask else { return }
        configureTimer(initialCall: false)
    }

    /// Removes all subscribers and tears down the timer.
    public func stopPolling() {
        let task = _state.withLock { state in
            state.handlers = [:]
            let task = state.pollingTask
            state.pollingTask = nil
            return task
        }
        continuation.finish()
        task?.cancel()
    }

    /// Updates the timer interval. Passing `nil` reverts to the default interval.
    /// If polling is active, the timer restarts immediately with the new cadence.
    /// Waits for the new interval to pass before triggering `handler` the first time.
    /// - Parameter newInterval: New interval in seconds, or `nil` to clear the override.
    public func updateInterval(_ newInterval: Duration?) {
        intervalOverride = newInterval
        let hasTask = _state.withLock { $0.pollingTask != nil }
        if hasTask {
            configureTimer(initialCall: false)
        }
    }

    // MARK: - Private helpers

    /// - Parameter initialCall: Trigger the callback on the first loop.
    private func configureTimer(initialCall: Bool) {
        // Cancel existing task before starting a new one
        let oldTask = _state.withLock { state in
            let old = state.pollingTask
            state.pollingTask = nil
            return old
        }
        oldTask?.cancel()

        let interval = effectiveInterval

        let newTask = Task { [weak self] in
            guard let self else {
                return
            }

            // We want to trigger the handler immediately when we start polling
            if initialCall {
                try await callHandlers()
            }

            while !Task.isCancelled {
                // Sleep for the configured interval using the injected clock
                try await clock.sleep(for: interval)

                try await callHandlers()
            }
        }
        _state.withLock { $0.pollingTask = newTask }
    }

    private func callHandlers() async throws {
        let handlers = _state.withLock { Array($0.handlers.values) }
        for handler in handlers {
            try await handler()
        }
        continuation.yield()
    }
}

// MARK: - Internal State

private struct PollerState {
    var handlers: [UUID: GenericTimerPoller.PollHandler] = [:]
    var pollingTask: Task<Void, Error>?
}
