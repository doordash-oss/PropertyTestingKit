//
//  FuzzStateMachine.swift
//  Copyright © 2026 DoorDash. All rights reserved.
//

import Foundation
import DequeModule


actor FuzzStateMachine<each Input> {
    let inputQueue: TestInputQueue<repeat each Input>
    let outputQueue: TestOutputQueue<repeat each Input>
    let workerPool: WorkerPool<repeat each Input>

    init(
        seeds: [(repeat each Input)],
        randomInputGenerator: @escaping () -> (repeat each Input)
    ) {
        let inputQueue = TestInputQueue(
            initialValues: seeds,
            randomInputGenerator: randomInputGenerator
        )
        self.outputQueue = outputQueue
        self.inputQueue = inputQueue
        self.workerPool = WorkerPool(inputQueue: inputQueue) { testInput in
            
        }
    }
}

actor TestInputQueue<each Input> {
    var queue: Deque<(repeat each Input)>
    let randomInputGenerator: () -> (repeat each Input)

    init(initialValues: [(repeat each Input)] = [], randomInputGenerator: @escaping () -> (repeat each Input)) {
        self.queue = Deque(initialValues)
        self.randomInputGenerator = randomInputGenerator
    }

    func pull() -> (repeat each Input) {
        return queue.popFirst() ?? randomInputGenerator()
    }

    func push(_ element: repeat each Input) {
        queue.append((repeat each element))
    }
}

actor TestOutputQueue<each Input> {
    var queue: Deque<TestResult<repeat each Input>>

    init() {
        self.queue = Deque()
    }

    func pull() -> (repeat each Input) {
        return queue.popFirst()
    }

    func push(_ element: TestResult<repeat each Input>) {
        queue.append(element)
    }
}

/// Pool that uses a pull system to request tasks on completion
actor WorkerPool<each Input> {
    let size: Int
    let inputQueue: TestInputQueue<repeat each Input>
    let test: (repeat each Input) async throws -> Void
    private var poolTask: Task<Void, Never>?

    init(
        size: Int = ProcessInfo.processInfo.processorCount,
        inputQueue: TestInputQueue<repeat each Input>,
        test: @escaping (repeat each Input) async throws -> Void
    ) {
        // Workers at least 1
        let size = max(1, size)
        self.size = size
        self.inputQueue = inputQueue
        self.outputQueue = outputQueue

        self.poolTask = createPoolTask()
    }

    deinit {
        poolTask?.cancel()
    }

    private func createPoolTask() -> Task<Void, any Error> {
        Task {
            try await withThrowingTaskGroup { group in
                for _ in 0..<self.size {
                    group.addTask {
                        while !Task.isCancelled {
                            let input = inputQueue.pull()
                            try await self.test(input)
                        }
                    }
                }
            }
        }
    }
}

/*
 task loop
 pull from queue
 */
