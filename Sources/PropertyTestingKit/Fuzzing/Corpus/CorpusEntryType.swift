//
//  CorpusEntryType.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// The reason this entry was added to the corpus.
public enum CorpusEntryType: String, Codable, Sendable {
    /// Entry was added because it discovered new coverage.
    case coverage

    /// Entry was added because it caused a test failure.
    case failure
}
