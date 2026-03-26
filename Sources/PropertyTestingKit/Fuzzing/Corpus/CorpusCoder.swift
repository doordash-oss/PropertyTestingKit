//
//  CorpusCoder.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

extension JSONEncoder {
    static func corpusEncoder(scheduleFuzzing: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if scheduleFuzzing {
            encoder.userInfo[.scheduleFuzzing] = true
        }
        return encoder
    }
}

extension JSONDecoder {
    static func corpusDecoder(scheduleFuzzing: Bool = false) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if scheduleFuzzing {
            decoder.userInfo[.scheduleFuzzing] = true
        }
        return decoder
    }
}
