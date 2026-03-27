//
// GenericTimerPoller.swift
// Copyright © 2026 DoorDash. All rights reserved.
//

import Clocks
import Dependencies
import Foundation

/// A handle to a poller subscription that cancels on deinit.
///
/// Works like `AnyCancellable` — reassigning the variable or letting it
/// go out of scope automatically cancels the underlying task.
public final class TaskCancellable: Sendable {
    private let task: Task<Void, Never>

    public init(_ task: Task<Void, Never>) {
        self.task = task
    }

    deinit {
        task.cancel()
    }

    /// Cancels the subscription immediately.
    public func cancel() {
        task.cancel()
    }
}

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
    public let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

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
        for cont in subscriberContinuations.values { cont.finish() }
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
        configureTimer(fireImmediately: true)
    }

    /// Registers the caller as a subscriber.
    ///
    /// The returned ``TaskCancellable`` automatically removes the subscriber
    /// when it is cancelled **or deallocated** — reassigning the variable or
    /// letting it go out of scope cancels the subscription, just like
    /// `AnyCancellable`.
    @discardableResult
    public func subscribe(handler: @escaping PollHandler) -> TaskCancellable {
        let id = UUID()
        handlers[id] = handler

        let (aliveStream, aliveContinuation) = AsyncStream<Void>.makeStream()
        subscriberContinuations[id] = aliveContinuation

        let task = Task { [weak self] in
            await withTaskCancellationHandler {
                for await _ in aliveStream {}
            } onCancel: {
                aliveContinuation.finish()
            }
            await self?.removeSubscriber(id)
        }
        return TaskCancellable(task)
    }

    /// Temporarily stops the timer but keeps subscriber bookkeeping intact.
    public func pausePolling() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Resumes polling if at least one subscriber is still registered.
    public func resumePolling() {
        guard !handlers.isEmpty, timerTask == nil else { return }
        configureTimer(fireImmediately: false)
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

    private func configureTimer(fireImmediately: Bool = false) {
        timerTask?.cancel()

        let task = Task { [weak self] in
            do {
                if fireImmediately {
                    guard let self else { return }
                    await self.callHandlers()
                }
                while !Task.isCancelled {
                    guard let self else { return }
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