//
//  ActionExecutor.swift
//  PropertyTestingKit
//
//  Executes plugin actions and collects results.
//

import Testing
import Foundation

// MARK: - Action Execution Result
//
///// Result of executing plugin actions.
/////
///// Contains all results from processing plugin actions, including
///// typed inputs for mutation and corpus submission.
//public struct ActionExecutionResult<each T: Sendable>: Sendable {
//    /// Whether a stop action was received.
//    public var shouldStop: Bool
//
//    /// The reason for stopping (if shouldStop is true).
//    public var stopReason: String?
//
//    /// Inputs to queue for mutation (encoded as Data).
//    public var inputsToQueue: [Data]
//
//    /// Number of issues that were recorded.
//    public var issuesRecorded: Int
//
//    /// Inputs selected for mutation (from selectForMutation actions).
//    public var inputsToMutate: [(repeat each T)]
//
//    /// Inputs to submit to the corpus (from submitToCorpus actions).
//    public var corpusInputs: [(repeat each T)]
//
//    public init(
//        shouldStop: Bool = false,
//        stopReason: String? = nil,
//        inputsToQueue: [Data] = [],
//        issuesRecorded: Int = 0,
//        inputsToMutate: [(repeat each T)] = [],
//        corpusInputs: [(repeat each T)] = []
//    ) {
//        self.shouldStop = shouldStop
//        self.stopReason = stopReason
//        self.inputsToQueue = inputsToQueue
//        self.issuesRecorded = issuesRecorded
//        self.inputsToMutate = inputsToMutate
//        self.corpusInputs = corpusInputs
//    }
//}
//
//// MARK: - Action Executor
//
///// Executes plugin actions and collects results.
/////
///// This is separated from FuzzEngine to allow unit testing of action execution logic.
//public struct ActionExecutor: Sendable {
//    /// Whether to actually record issues (set to false for testing).
//    private let recordIssues: Bool
//
//    /// Creates an action executor.
//    ///
//    /// - Parameter recordIssues: Whether to record issues via Swift Testing.
//    ///   Set to `false` for unit testing to avoid side effects.
//    public init(recordIssues: Bool = true) {
//        self.recordIssues = recordIssues
//    }
//
//    /// Execute plugin actions and return results.
//    ///
//    /// Processes all plugin actions:
//    /// - `.stop` - Captures stop reason
//    /// - `.recordIssue` - Records issue (if enabled) and counts it
//    /// - `.queueInputs` - Collects inputs to queue
//    /// - `.selectForMutation` - Collects inputs selected for mutation
//    /// - `.submitToCorpus` - Collects inputs to submit to corpus
//    ///
//    /// - Parameter actions: The actions to execute.
//    /// - Returns: The result of executing the actions.
//    public func execute<each T: Sendable>(
//        _ actions: [FuzzPluginAction<repeat each T>]
//    ) -> ActionExecutionResult<repeat each T> {
//        var result = ActionExecutionResult<repeat each T>()
//
//        for action in actions {
//            switch action {
//            case .stop(let stopAction):
//                result.shouldStop = true
//                result.stopReason = stopAction.reason
//
//            case .recordIssue(let issueAction):
//                result.issuesRecorded += 1
//                if recordIssues {
//                    Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)
//                }
//
//            case .queueInputs(let queueAction):
//                result.inputsToQueue.append(contentsOf: queueAction.inputs)
//
//            case .selectForMutation(let selectAction):
//                result.inputsToMutate.append(selectAction.input)
//
//            case .submitToCorpus(let corpusAction):
//                result.corpusInputs.append(corpusAction.input)
//            }
//        }
//
//        return result
//    }
//}
