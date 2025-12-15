//
//  StringDictionary.swift
//  PropertyTestingKit
//
//  Swift wrapper for string allocation hooks.
//  Captures magic strings at runtime to guide string mutations.
//

import Foundation
import StringAllocationHooks

/// Captures strings created during test execution to build a mutation dictionary.
///
/// Uses fishhook to intercept Swift's string literal initializer, capturing
/// all strings created at runtime - including dynamically constructed ones.
///
/// Example:
/// ```swift
/// let dictionary = StringDictionary.shared
/// dictionary.startCapture()
/// _ = checkPassword("test")  // Internally compares against "secretPassword123"
/// dictionary.stopCapture()
///
/// print(dictionary.strings)  // ["secretPassword123", ...]
/// ```
public final class StringDictionary: @unchecked Sendable {
    /// Shared instance for global string capture.
    public static let shared = StringDictionary()

    /// Lock for thread safety.
    private let lock = NSLock()

    /// Accumulated strings across multiple capture sessions.
    private var accumulatedStrings: Set<String> = []

    /// Whether hooks are available (fishhook succeeded).
    public var isAvailable: Bool {
        sah_is_available()
    }

    /// Whether capture is currently active.
    public var isCapturing: Bool {
        sah_is_enabled()
    }

    /// All captured strings (accumulated across sessions).
    public var strings: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedStrings
    }

    /// Number of unique strings captured.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedStrings.count
    }

    private init() {
        // Initialize hooks on first access
        sah_initialize()
    }

    /// Start capturing strings.
    ///
    /// All strings created while capturing is active will be recorded.
    /// Call `stopCapture()` to stop and retrieve the strings.
    public func startCapture() {
        sah_clear()
        sah_enable()
    }

    /// Stop capturing and accumulate the captured strings.
    ///
    /// - Returns: The strings captured during this session.
    @discardableResult
    public func stopCapture() -> [String] {
        sah_disable()

        let count = sah_get_count()
        var sessionStrings: [String] = []

        lock.lock()
        for i in 0..<count {
            if let cStr = sah_get_string(i) {
                let str = String(cString: cStr)
                sessionStrings.append(str)
                accumulatedStrings.insert(str)
            }
        }
        lock.unlock()

        return sessionStrings
    }

    /// Clear all accumulated strings.
    public func clear() {
        lock.lock()
        accumulatedStrings.removeAll()
        lock.unlock()
        sah_clear()
    }

    /// Add strings manually to the dictionary.
    ///
    /// Useful for adding known magic strings or user-provided dictionaries.
    public func add(_ strings: [String]) {
        lock.lock()
        for str in strings {
            accumulatedStrings.insert(str)
        }
        lock.unlock()
    }

    /// Add a single string to the dictionary.
    public func add(_ string: String) {
        lock.lock()
        accumulatedStrings.insert(string)
        lock.unlock()
    }

    /// Capture strings during a block execution.
    ///
    /// - Parameter body: The code to execute while capturing.
    /// - Returns: A tuple of the block's result and the captured strings.
    public func capture<T>(during body: () throws -> T) rethrows -> (result: T, strings: [String]) {
        startCapture()
        let result = try body()
        let strings = stopCapture()
        return (result, strings)
    }

    /// Capture strings during an async block execution.
    @available(macOS 10.15, iOS 13.0, *)
    public func capture<T>(during body: () async throws -> T) async rethrows -> (result: T, strings: [String]) {
        startCapture()
        let result = try await body()
        let strings = stopCapture()
        return (result, strings)
    }
}

// MARK: - String Mutator Integration

extension StringDictionary {
    /// Get strings suitable for mutation (filtered and sorted by length).
    ///
    /// Returns strings sorted by length (shorter first), which are often
    /// more useful as mutation targets.
    public var mutationCandidates: [String] {
        lock.lock()
        defer { lock.unlock() }

        return accumulatedStrings
            .filter { $0.count >= 2 && $0.count <= 100 }
            .sorted { $0.count < $1.count }
    }

    /// Get a random string from the dictionary for mutation.
    public func randomString() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard !accumulatedStrings.isEmpty else { return nil }
        return accumulatedStrings.randomElement()
    }

    /// Get strings that might be related to a given string.
    ///
    /// Finds strings that share a common prefix or are similar in structure.
    public func relatedStrings(to string: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let prefix = String(string.prefix(3))
        return accumulatedStrings.filter { candidate in
            candidate != string && (
                candidate.hasPrefix(prefix) ||
                string.hasPrefix(String(candidate.prefix(3)))
            )
        }
    }
}
