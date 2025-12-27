//
//  FuzzObserverPlugin.swift
//  PropertyTestingKit
//
//  Observer plugins receive notifications about fuzzing lifecycle events.
//  All methods have default empty implementations, so plugins only need
//  to implement the events they care about.
//

import Foundation

/// Plugin protocol for observing fuzzing lifecycle events.
/// All methods have default empty implementations.
public protocol FuzzObserverPlugin: FuzzPlugin {
    /// Called when fuzzing starts.
    func onStart(context: FuzzPluginContext.StartContext) async

    /// Called after each iteration completes.
    func onIteration(context: FuzzPluginContext.IterationContext) async

    /// Called after each batch of inputs is processed.
    func onBatchComplete(context: FuzzPluginContext.BatchContext) async

    /// Called when fuzzing ends.
    func onEnd(context: FuzzPluginContext.EndContext) async
}

// MARK: - Default Implementations

extension FuzzObserverPlugin {
    public func onStart(context: FuzzPluginContext.StartContext) async {}
    public func onIteration(context: FuzzPluginContext.IterationContext) async {}
    public func onBatchComplete(context: FuzzPluginContext.BatchContext) async {}
    public func onEnd(context: FuzzPluginContext.EndContext) async {}
}
