//
//  CorpusCoder.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

extension JSONEncoder {
    static let corpusEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        return encoder
    }()
}

extension JSONDecoder {
    static let corpusDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return decoder
    }()
}
