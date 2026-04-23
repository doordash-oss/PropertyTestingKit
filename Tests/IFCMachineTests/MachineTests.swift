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

//  Tests for the IFC machine — verifies execution, label propagation,
//  indistinguishability, and SSNI.
//

import Testing
@testable import IFCMachine

// MARK: - Execution Tests

@Suite("IFC Machine Execution")
struct MachineExecutionTests {

    @Test("Halt stops execution")
    func haltStops() {
        let state = MachineState(instructions: [.halt])
        let result = step(state)
        guard case .halted(let final) = result else {
            Issue.record("Expected halted state")
            return
        }
        #expect(final.halted)
    }

    @Test("Put loads constant into register")
    func putLoadsConstant() {
        let state = MachineState(instructions: [.put(42, 0), .halt])
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok, got \(result)")
            return
        }
        #expect(next.registers[0].value == .int(42))
        #expect(next.registers[0].label == .low) // BOT
        #expect(next.pc == 1)
    }

    @Test("Mov copies value with source label")
    func movCopiesValue() {
        var state = MachineState(instructions: [.mov(0, 1), .halt])
        state.registers[0] = .int(42, .high)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.registers[1].value == .int(42))
        #expect(next.registers[1].label == .high)
    }

    @Test("BinOp add works")
    func binOpAdd() {
        var state = MachineState(instructions: [.binOp(.add, 0, 1, 2), .halt])
        state.registers[0] = .int(3, .low)
        state.registers[1] = .int(7, .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.registers[2].value == .int(10))
    }

    @Test("BinOp eq compares values")
    func binOpEq() {
        var state = MachineState(instructions: [.binOp(.eq, 0, 1, 2), .halt])
        state.registers[0] = .int(5, .low)
        state.registers[1] = .int(5, .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.registers[2].value == .int(1))
    }

    @Test("Load reads from frame memory via pointer")
    func loadReadsMemory() {
        var state = MachineState(instructions: [.load(0, 1), .halt])
        // r0 = ptr(block:1, offset:2)
        state.registers[0] = Atom(.ptr(block: 1, offset: 2), .low)
        state.frames[1].contents[2] = .int(99, .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok, got \(result)")
            return
        }
        #expect(next.registers[1].value == .int(99))
    }

    @Test("Store writes to frame memory via pointer")
    func storeWritesMemory() {
        var state = MachineState(instructions: [.store(0, 1), .halt])
        // r0 = ptr(block:0, offset:3), frame 0 is LOW
        state.registers[0] = Atom(.ptr(block: 0, offset: 3), .low)
        state.registers[1] = .int(77, .low)
        state.frames[0].label = .low
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok, got \(result)")
            return
        }
        #expect(next.frames[0].contents[3].value == .int(77))
    }

    @Test("BNZ branches when non-zero")
    func bnzBranches() {
        var state = MachineState(instructions: [.bnz(3, 0), .nop, .nop, .halt])
        state.registers[0] = .int(1, .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.pc == 3)
    }

    @Test("BNZ falls through when zero")
    func bnzFallsThrough() {
        var state = MachineState(instructions: [.bnz(3, 0), .halt])
        state.registers[0] = .int(0, .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.pc == 1)
    }

    @Test("Jump sets PC from register")
    func jumpSetsPC() {
        var state = MachineState(instructions: [.jump(0), .nop, .halt])
        state.registers[0] = .int(2, .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.pc == 2)
    }

    @Test("Lab extracts label from register")
    func labExtractsLabel() {
        var state = MachineState(instructions: [.lab(0, 1), .halt])
        state.registers[0] = .int(42, .high)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.registers[1].value == .label(.high))
        #expect(next.registers[1].label == .low) // BOT
    }

    @Test("PcLab reads PC label")
    func pcLabReadsPCLabel() {
        var state = MachineState(instructions: [.pcLab(0), .halt])
        state.pcLabel = .high
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.registers[0].value == .label(.high))
    }

    @Test("Call and Ret round-trip")
    func callAndRet() {
        var state = MachineState(instructions: [
            .call(0, 1, 2),   // 0: call target=r0, retBound=r1, result=r2
            .halt,             // 1: (return here)
            .nop,              // 2: padding
            .put(99, 2),       // 3: put 99 into r2 (the result register)
            .ret               // 4: return
        ])
        state.registers[0] = .int(3, .low)
        state.registers[1] = Atom(.label(.low), .low)

        let final = run(state, maxSteps: 10)
        #expect(final.halted)
        #expect(final.registers[2].value == .int(99))
    }

    @Test("Run executes full program")
    func runExecutesProgram() {
        let state = MachineState(instructions: [
            .put(10, 0),
            .put(20, 1),
            .binOp(.add, 0, 1, 2),
            .halt
        ])
        let final = run(state)
        #expect(final.halted)
        #expect(final.registers[2].value == .int(30))
    }

    @Test("Alloc creates new frame and returns pointer")
    func allocCreatesFrame() {
        var state = MachineState(instructions: [.alloc(0, 1, 2), .halt])
        state.registers[0] = .int(3, .low)                    // size = 3
        state.registers[1] = Atom(.label(.low), .low)          // frame label = low
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok, got \(result)")
            return
        }
        let initialFrameCount = MachineState.defaultFrameCount
        #expect(next.frames.count == initialFrameCount + 1)
        #expect(next.frames[initialFrameCount].contents.count == 3)
        #expect(next.frames[initialFrameCount].label == .low)
        guard case .ptr(let block, let offset) = next.registers[2].value else {
            Issue.record("Expected pointer in r2")
            return
        }
        #expect(block == initialFrameCount)
        #expect(offset == 0)
    }

    @Test("PGetOff extracts pointer offset")
    func pGetOffExtractsOffset() {
        var state = MachineState(instructions: [.pGetOff(0, 1), .halt])
        state.registers[0] = Atom(.ptr(block: 2, offset: 3), .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok, got \(result)")
            return
        }
        #expect(next.registers[1].value == .int(3))
    }

    @Test("PSetOff creates pointer with new offset")
    func pSetOffCreatesPointer() {
        var state = MachineState(instructions: [.pSetOff(0, 1, 2), .halt])
        state.registers[0] = Atom(.ptr(block: 1, offset: 0), .low)
        state.registers[1] = .int(2, .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok, got \(result)")
            return
        }
        #expect(next.registers[2].value == .ptr(block: 1, offset: 2))
    }

    @Test("MSize returns frame size")
    func mSizeReturnsFrameSize() {
        var state = MachineState(instructions: [.mSize(0, 1), .halt])
        state.registers[0] = Atom(.ptr(block: 0, offset: 0), .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok, got \(result)")
            return
        }
        #expect(next.registers[1].value == .int(MachineState.defaultFrameSize))
    }

    @Test("MLab returns frame label")
    func mLabReturnsFrameLabel() {
        var state = MachineState(instructions: [.mLab(0, 1), .halt])
        state.registers[0] = Atom(.ptr(block: 2, offset: 0), .low)
        state.frames[2].label = .high
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok, got \(result)")
            return
        }
        #expect(next.registers[1].value == .label(.high))
    }
}

// MARK: - Label Propagation Tests

@Suite("IFC Label Propagation")
struct LabelPropagationTests {

    @Test("BinOp joins labels from both operands")
    func binOpJoinsLabels() {
        var state = MachineState(instructions: [.binOp(.add, 0, 1, 2), .halt])
        state.registers[0] = .int(1, .low)
        state.registers[1] = .int(2, .high)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.registers[2].label == .high)
    }

    @Test("Store blocks high-to-low write via pointer")
    func storeBlocksHighToLow() {
        var state = MachineState(instructions: [.store(0, 1), .halt])
        // HIGH pointer to frame 0 (which has LOW frame label)
        state.registers[0] = Atom(.ptr(block: 0, offset: 0), .high)
        state.registers[1] = .int(77, .low)
        state.frames[0].label = .low
        // join(ptrLabel=high, pc=low) = high, does NOT flow to frameLabel=low
        let result = step(state)
        guard case .error(.securityViolation) = result else {
            Issue.record("Expected security violation, got \(result)")
            return
        }
    }

    @Test("BNZ taints PC with test register label")
    func bnzTaintsPC() {
        var state = MachineState(instructions: [.bnz(1, 0), .halt])
        state.registers[0] = .int(1, .high)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.pcLabel == .high)
    }

    @Test("Load taints PC with pointer and frame labels")
    func loadTaintsPC() {
        var state = MachineState(instructions: [.load(0, 1), .halt])
        // HIGH pointer to frame 0 (LOW frame label)
        state.registers[0] = Atom(.ptr(block: 0, offset: 0), .high)
        state.frames[0].label = .low
        state.frames[0].contents[0] = .int(42, .low)
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        // newPC = join(pc=low, join(ptr=high, frame=low)) = high
        #expect(next.pcLabel == .high)
    }

    @Test("Put gives result BOT label regardless of PC")
    func putGivesBotLabel() {
        var state = MachineState(instructions: [.put(42, 0), .halt])
        state.pcLabel = .high
        let result = step(state)
        guard case .ok(let next) = result else {
            Issue.record("Expected ok")
            return
        }
        #expect(next.registers[0].label == .low)
    }

    @Test("Ret blocks when return value too high")
    func retBlocksHighReturn() {
        var state = MachineState(instructions: [.ret])
        state.pcLabel = .high
        state.registers[0] = .int(42, .high)
        state.stack = [StackFrame(
            returnPC: 0,
            returnPCLabel: .low,
            savedRegisters: Array(repeating: .int(0, .low), count: 8),
            resultReg: 0,
            resultLabel: .low
        )]
        let result = step(state)
        guard case .error(.securityViolation) = result else {
            Issue.record("Expected security violation, got \(result)")
            return
        }
    }
}

// MARK: - Indistinguishability Tests

@Suite("Indistinguishability")
struct IndistinguishabilityTests {

    @Test("Identical states are indistinguishable")
    func identicalStates() {
        let state = MachineState(instructions: [.halt])
        #expect(indistinguishable(state, state))
    }

    @Test("States differing in high registers are indistinguishable")
    func highRegsDiffer() {
        var s1 = MachineState(instructions: [.halt])
        var s2 = MachineState(instructions: [.halt])
        s1.registers[0] = .int(42, .high)
        s2.registers[0] = .int(99, .high)
        #expect(indistinguishable(s1, s2))
    }

    @Test("States differing in low registers are distinguishable")
    func lowRegsDiffer() {
        var s1 = MachineState(instructions: [.halt])
        var s2 = MachineState(instructions: [.halt])
        s1.registers[0] = .int(42, .low)
        s2.registers[0] = .int(99, .low)
        #expect(!indistinguishable(s1, s2))
    }

    @Test("States with both PCs high only compare cropped stacks")
    func highPCsUseCroppedStacks() {
        var s1 = MachineState(instructions: [.halt])
        var s2 = MachineState(instructions: [.halt])
        s1.pcLabel = .high
        s2.pcLabel = .high
        s1.pc = 0
        s2.pc = 0
        s1.registers[0] = .int(1, .low)
        s2.registers[0] = .int(2, .low)
        // Both PCs high: low register differences not compared
        #expect(indistinguishable(s1, s2))
    }

    @Test("Atom indistinguishability: labels must match")
    func atomLabelsMustMatch() {
        let a = Atom(.int(42), .low)
        let b = Atom(.int(42), .high)
        #expect(!indistAtom(a, b, observer: .low))
    }

    @Test("High-labeled frames are invisible")
    func highFrameIsInvisible() {
        var s1 = MachineState(instructions: [.halt])
        var s2 = MachineState(instructions: [.halt])
        s1.frames[0].label = .high
        s2.frames[0].label = .high
        // Different contents in high frame — should still be indistinguishable
        s1.frames[0].contents[0] = .int(1, .low)
        s2.frames[0].contents[0] = .int(999, .high)
        #expect(indistinguishable(s1, s2))
    }
}

// MARK: - SSNI Tests

@Suite("Single-Step Noninterference")
struct SSNITests {

    @Test("Correct rules satisfy SSNI for put instruction")
    func putSSNI() {
        var s1 = MachineState(instructions: [.put(10, 0), .halt])
        var s2 = s1
        s1.registers[1] = .int(100, .high)
        s2.registers[1] = .int(200, .high)

        let violation = checkSSNI(s1, s2)
        #expect(violation == nil)
    }

    @Test("Correct rules satisfy SSNI for binop with mixed labels")
    func binopSSNI() {
        var s1 = MachineState(instructions: [.binOp(.add, 0, 1, 2), .halt])
        var s2 = s1
        s1.registers[0] = .int(5, .low)
        s2.registers[0] = .int(5, .low)
        s1.registers[1] = .int(10, .high)
        s2.registers[1] = .int(20, .high)

        let violation = checkSSNI(s1, s2)
        #expect(violation == nil)
    }

    @Test("Correct rules satisfy SSNI for bnz with high test")
    func bnzHighSSNI() {
        var s1 = MachineState(instructions: [.bnz(2, 0), .nop, .halt])
        var s2 = s1
        s1.registers[0] = .int(1, .high)
        s2.registers[0] = .int(0, .high)

        let violation = checkSSNI(s1, s2)
        #expect(violation == nil, "SSNI should hold: high branch → high PC, states indistinguishable")
    }
}
