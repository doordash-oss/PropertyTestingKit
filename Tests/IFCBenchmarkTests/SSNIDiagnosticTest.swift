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

//
//  SSNIDiagnosticTest.swift
//  IFCBenchmarkTests
//
//  Diagnostic test to find what's causing SSNI violations with the correct table.
//

import Testing
import IFCMachine
@testable import PropertyTestingKit

@Suite("SSNI Diagnostics")
struct SSNIDiagnosticTests {

    @Test("Find and report SSNI violation details")
    func findViolation() async throws {
        try await fuzz(
            duration: .seconds(10),
            corpusMode: .refuzzReplace,
            parallelism: 1
        ) { (variation: Variation) in
            let obs = variation.observer
            let st1 = variation.state1
            let st2 = variation.state2

            guard indistinguishable(st1, st2, observer: obs) else { return }

            let r1 = step(st1)
            guard case .ok(let st1p) = r1 else { return }

            let st1Low = st1.pcLabel.flowsTo(obs)

            if st1Low {
                let r2 = step(st2)
                guard case .ok(let st2p) = r2 else { return }

                if !indistinguishable(st1p, st2p, observer: obs) {
                    // Found a violation! Print diagnostic info
                    let instr = st1.instructions[st1.pc]
                    print("=== SSNI LOW->* VIOLATION ===")
                    print("Observer: \(obs)")
                    print("PC: \(st1.pc), instruction: \(instr)")
                    print("PC label: \(st1.pcLabel)")
                    print("---")
                    print("st1 regs: \(st1.registers.map { "(\($0.value), \($0.label))" })")
                    print("st2 regs: \(st2.registers.map { "(\($0.value), \($0.label))" })")
                    print("---")
                    print("st1' pc=\(st1p.pc) pcLabel=\(st1p.pcLabel)")
                    print("st2' pc=\(st2p.pc) pcLabel=\(st2p.pcLabel)")
                    print("st1' regs: \(st1p.registers.map { "(\($0.value), \($0.label))" })")
                    print("st2' regs: \(st2p.registers.map { "(\($0.value), \($0.label))" })")

                    // Check which component diverges
                    if st1p.pc != st2p.pc { print("DIVERGED: pc") }
                    if st1p.pcLabel != st2p.pcLabel { print("DIVERGED: pcLabel") }
                    for i in 0..<min(st1p.registers.count, st2p.registers.count) {
                        if !indistAtom(st1p.registers[i], st2p.registers[i], observer: obs) {
                            print("DIVERGED: register \(i): \(st1p.registers[i]) vs \(st2p.registers[i])")
                        }
                    }
                    for fi in 0..<min(st1p.frames.count, st2p.frames.count) {
                        for ci in 0..<min(st1p.frames[fi].contents.count, st2p.frames[fi].contents.count) {
                            let a = st1p.frames[fi].contents[ci]
                            let b = st2p.frames[fi].contents[ci]
                            if !indistAtom(a, b, observer: obs) {
                                print("DIVERGED: frame[\(fi)][\(ci)]: \(a) vs \(b)")
                            }
                        }
                    }
                    print("==============================")

                    #expect(Bool(false), "SSNI violation found — see diagnostic output above")
                }
            } else {
                let st1pLow = st1p.pcLabel.flowsTo(obs)
                if !st1pLow {
                    // HIGH -> HIGH
                    if !indistinguishable(st1, st1p, observer: obs) {
                        let instr = st1.instructions[st1.pc]
                        print("=== SSNI HIGH->HIGH VIOLATION ===")
                        print("Observer: \(obs)")
                        print("PC: \(st1.pc), instruction: \(instr)")
                        print("PC label before: \(st1.pcLabel), after: \(st1p.pcLabel)")

                        for fi in 0..<min(st1.frames.count, st1p.frames.count) {
                            for ci in 0..<min(st1.frames[fi].contents.count, st1p.frames[fi].contents.count) {
                                let a = st1.frames[fi].contents[ci]
                                let b = st1p.frames[fi].contents[ci]
                                if !indistAtom(a, b, observer: obs) {
                                    print("DIVERGED: frame[\(fi)][\(ci)]: \(a) vs \(b)")
                                }
                            }
                        }
                        print("==================================")

                        #expect(Bool(false), "SSNI HIGH->HIGH violation found")
                    }
                }
            }
        }
    }
}
