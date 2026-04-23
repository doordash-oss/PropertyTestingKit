// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Clocks
import Dependencies
import Foundation

/// A reusable timer-based poller.
///
/// Usage:
/// ```swift
/// let poller = GenericTimerPoller()
/// let task = poller.subscribe { /* Timed activity here */ } // retain the task while you need updates
/// poller.startPolling()
/// // ... later
/// task.cancel() // removes one subscriber; timer stops when the last subscriber is gone
/// ```
public actor GenericTimerPoller {
    /// Handler that gets executed each time the timer fires.
    public typealias PollHandler = () async -> Void

    /// Used for testing, emits when handlers emit
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation

    /// Clock used for sleeping between polls (injectable for tests)
    @Dependency(\.continuousClock) var clock

    // Polling intervals
    var defaultInterval: Duration
    var intervalOverride: Duration?

    // Actor-isolated state
    private var handlers: [UUID: PollHandler] = [:]
    private var subscriberContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var timerTask: Task<Void, Never>?

    private var onDeinitCallback: (@Sendable () -> Void)?

    deinit {
        timerTask?.cancel()
        continuation.finish()
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
    public init(
        defaultInterval: Duration = .seconds(60), line: Int = #line, function: String = #function,
        file: String = #filePath
    ) {
        self.line = line
        self.function = function
        self.file = file
        self.defaultInterval = defaultInterval
        (self.stream, self.continuation) = AsyncStream<Void>.makeStream()
    }

    // MARK: - Public API

    /// Starts (or restarts) the timer-driven polling
    public func startPolling() {
        configureTimer()

        // Call handlers immediately
        Task {
            await callHandlers()
        }
    }

    /// Registers the caller as a subscriber.
    ///
    /// The returned `Task` automatically removes the caller when it is cancelled.
    /// Cancellation is synchronous — `task.cancel()` works in `deinit` just like `AnyCancellable.cancel()` did.
    @discardableResult
    public func subscribe(handler: @escaping PollHandler) -> Task<Void, Never> {
        let id = UUID()
        handlers[id] = handler

        let (aliveStream, aliveContinuation) = AsyncStream<Void>.makeStream()
        subscriberContinuations[id] = aliveContinuation

        return Task { [weak self] in
            await withTaskCancellationHandler {
                for await _ in aliveStream {}
            } onCancel: {
                aliveContinuation.finish()
            }
            await self?.removeSubscriber(id)
        }
    }

    /// Temporarily stops the timer but keeps subscriber bookkeeping intact.
    public func pausePolling() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Resumes polling if at least one subscriber is still registered.
    public func resumePolling() {
        guard !handlers.isEmpty, timerTask == nil else { return }
        configureTimer()
    }

    /// Removes all subscribers and tears down the timer.
    public func stopPolling() {
        timerTask?.cancel()
        timerTask = nil
        handlers = [:]
        for cont in subscriberContinuations.values { cont.finish() }
        subscriberContinuations = [:]
        continuation.finish()
    }

    /// Updates the timer interval. Passing `nil` reverts to the default interval.
    /// If polling is active, the timer restarts immediately with the new cadence.
    /// Waits for the new interval to pass before triggering `handler` the first time.
    /// - Parameter newInterval: New interval in seconds, or `nil` to clear the override.
    public func updateInterval(_ newInterval: Duration?) {
        intervalOverride = newInterval
        if timerTask != nil {
            configureTimer()
        }
    }

    // MARK: - Private helpers

    private func removeSubscriber(_ id: UUID) {
        handlers[id] = nil
        subscriberContinuations[id] = nil
        if handlers.isEmpty {
            timerTask?.cancel()
            timerTask = nil
            continuation.finish()
        }
    }

    private func configureTimer() {
        timerTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    try await self.clock.sleep(for: self.effectiveInterval)
                    await self.callHandlers()
                }
            } catch {
                // CancellationError or handler error
            }
        }
        timerTask = task
    }

    private func callHandlers() async {
        for handler in handlers.values {
            await handler()
        }
        continuation.yield()
    }
}
