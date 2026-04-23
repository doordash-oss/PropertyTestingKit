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

//  Single-step execution for the IFC register machine.
//  Ported from QuickChick/IFC Machine.v fstep.
//

/// Result of a single execution step.
public enum StepResult: Sendable {
    case ok(MachineState)
    case halted(MachineState)
    case error(MachineError)
}

/// Machine execution errors.
public enum MachineError: Error, Sendable, Hashable {
    case pcOutOfBounds
    case invalidRegister(Reg)
    case invalidPointer
    case securityViolation(String)
    case typeError(String)
    case stackUnderflow
}

/// Execute a single step of the IFC machine.
///
/// Follows the Coq `fstep` function from Machine.v.
public func step(_ state: MachineState, rules: RuleTable = .correct) -> StepResult {
    if state.halted {
        return .halted(state)
    }

    guard state.pc >= 0, state.pc < state.instructions.count else {
        return .error(.pcOutOfBounds)
    }

    var s = state
    let instruction = s.instructions[s.pc]

    switch instruction {

    // Halt: fstep returns None
    case .halt:
        s.halted = true
        return .halted(s)

    // Nop: << TRUE, __, LabPC >> — no result, PC advances
    case .nop:
        guard let (_, newPC) = rules.nopRule(s.pcLabel) else {
            return .error(.securityViolation("nop"))
        }
        s.pcLabel = newPC
        s.pc += 1

    // Put n r: r := Vint n, << TRUE, BOT, LabPC >>
    case .put(let n, let r):
        guard let _ = validReg(r, s) else { return .error(.invalidRegister(r)) }
        guard let (resultLabel, newPC) = rules.putRule(s.pcLabel) else {
            return .error(.securityViolation("put"))
        }
        s.registers[r] = Atom(.int(n), resultLabel ?? .low)
        s.pcLabel = newPC
        s.pc += 1

    // Mov r1 r2: r2 := r1, << TRUE, Lab1, LabPC >>
    case .mov(let src, let dst):
        guard let srcAtom = validReg(src, s), let _ = validReg(dst, s) else {
            return .error(.invalidRegister(src))
        }
        guard let (resultLabel, newPC) = rules.movRule(srcAtom.label, s.pcLabel) else {
            return .error(.securityViolation("mov"))
        }
        s.registers[dst] = Atom(srcAtom.value, resultLabel ?? srcAtom.label)
        s.pcLabel = newPC
        s.pc += 1

    // BinOp o r1 r2 r3: r3 := r1 op r2, << TRUE, JOIN Lab1 Lab2, LabPC >>
    case .binOp(let op, let r1, let r2, let r3):
        guard let a1 = validReg(r1, s), let a2 = validReg(r2, s), let _ = validReg(r3, s) else {
            return .error(.invalidRegister(r1))
        }
        guard let (resultLabel, newPC) = rules.binOpRule(a1.label, a2.label, s.pcLabel) else {
            return .error(.securityViolation("binOp"))
        }
        guard let resultValue = evalBinOp(op, a1.value, a2.value) else {
            return .error(.typeError("binOp type mismatch"))
        }
        s.registers[r3] = Atom(resultValue, resultLabel ?? a1.label.join(a2.label))
        s.pcLabel = newPC
        s.pc += 1

    // Load r1 r2: r2 := mem[r1], << TRUE, Lab3, JOIN LabPC (JOIN Lab1 Lab2) >>
    // r1 must contain a Vptr. Lab1=ptrLabel, Lab2=frameLabel, Lab3=memValueLabel.
    case .load(let ptrReg, let dstReg):
        guard let ptrAtom = validReg(ptrReg, s), let _ = validReg(dstReg, s) else {
            return .error(.invalidRegister(ptrReg))
        }
        guard case .ptr(let block, let offset) = ptrAtom.value,
              block >= 0, block < s.frames.count,
              offset >= 0, offset < s.frames[block].contents.count else {
            return .error(.invalidPointer)
        }
        let memAtom = s.frames[block].contents[offset]
        let frameLabel = s.frames[block].label
        guard let (resultLabel, newPC) = rules.loadRule(ptrAtom.label, frameLabel, memAtom.label, s.pcLabel) else {
            return .error(.securityViolation("load"))
        }
        s.registers[dstReg] = Atom(memAtom.value, resultLabel ?? memAtom.label)
        s.pcLabel = newPC
        s.pc += 1

    // Store r1 r2: mem[r1] := r2, << LE (JOIN Lab1 LabPC) Lab2, Lab3, LabPC >>
    // r1 must contain a Vptr. Lab1=ptrLabel, Lab2=frameLabel, Lab3=valueLabel.
    case .store(let ptrReg, let valReg):
        guard let ptrAtom = validReg(ptrReg, s), let valAtom = validReg(valReg, s) else {
            return .error(.invalidRegister(ptrReg))
        }
        guard case .ptr(let block, let offset) = ptrAtom.value,
              block >= 0, block < s.frames.count,
              offset >= 0, offset < s.frames[block].contents.count else {
            return .error(.invalidPointer)
        }
        let frameLabel = s.frames[block].label
        guard let (resultLabel, newPC) = rules.storeRule(ptrAtom.label, frameLabel, valAtom.label, s.pcLabel) else {
            return .error(.securityViolation("store: information flow violation"))
        }
        s.frames[block].contents[offset] = Atom(valAtom.value, resultLabel ?? valAtom.label)
        s.pcLabel = newPC
        s.pc += 1

    // Write r1 r2: mem[r1] := r2, << LE (JOIN (JOIN LabPC Lab1) Lab3) (JOIN Lab2 Lab4), Lab4, LabPC >>
    // Stronger update rule: also constrains the value label.
    // Lab1=ptrLabel, Lab2=frameLabel, Lab3=valueLabel, Lab4=cellLabel.
    case .write(let ptrReg, let valReg):
        guard let ptrAtom = validReg(ptrReg, s), let valAtom = validReg(valReg, s) else {
            return .error(.invalidRegister(ptrReg))
        }
        guard case .ptr(let block, let offset) = ptrAtom.value,
              block >= 0, block < s.frames.count,
              offset >= 0, offset < s.frames[block].contents.count else {
            return .error(.invalidPointer)
        }
        let frameLabel = s.frames[block].label
        let cellLabel = s.frames[block].contents[offset].label
        guard let (resultLabel, newPC) = rules.writeRule(ptrAtom.label, frameLabel, valAtom.label, cellLabel, s.pcLabel) else {
            return .error(.securityViolation("write: information flow violation"))
        }
        s.frames[block].contents[offset] = Atom(valAtom.value, resultLabel ?? cellLabel)
        s.pcLabel = newPC
        s.pc += 1

    // Alloc r1 r2 r3: r3 := alloc(size=r1, label=r2), << TRUE, JOIN Lab1 Lab2, LabPC >>
    // r1 must be Vint (size), r2 must be Vlab (frame label). Returns Vptr to new block.
    case .alloc(let sizeReg, let labReg, let dstReg):
        guard let sizeAtom = validReg(sizeReg, s),
              let labAtom = validReg(labReg, s),
              let _ = validReg(dstReg, s) else {
            return .error(.invalidRegister(sizeReg))
        }
        guard case .int(let size) = sizeAtom.value, size > 0 else {
            return .error(.typeError("alloc requires positive integer size"))
        }
        guard case .label(let frameLabel) = labAtom.value else {
            return .error(.typeError("alloc r2 must be a label value"))
        }
        guard let (resultLabel, newPC) = rules.allocRule(sizeAtom.label, labAtom.label, s.pcLabel) else {
            return .error(.securityViolation("alloc"))
        }
        // stamp = JOIN(sizeLabel, labLabel, pcLabel) — from Coq alloc:
        //   alloc i Ll (K ∪ K' ∪ LPC) ... where K=sizeAtom.label, K'=labAtom.label
        // HIGH stamp → frame invisible to LOW observer, preventing false SSNI violations
        // when alloc runs under a HIGH PC or with HIGH-labeled operands.
        let stamp = sizeAtom.label.join(labAtom.label).join(s.pcLabel)
        let newBlock = s.frames.count
        s.frames.append(Frame(
            label: frameLabel,
            stamp: stamp,
            contents: Array(repeating: Atom(.int(0), .low), count: size)
        ))
        s.registers[dstReg] = Atom(.ptr(block: newBlock, offset: 0), resultLabel ?? sizeAtom.label.join(labAtom.label))
        s.pcLabel = newPC
        s.pc += 1

    // PGetOff r1 r2: r2 := offset(r1), << TRUE, Lab1, LabPC >>
    // r1 must contain a Vptr. Returns the offset as Vint.
    case .pGetOff(let ptrReg, let dstReg):
        guard let ptrAtom = validReg(ptrReg, s), let _ = validReg(dstReg, s) else {
            return .error(.invalidRegister(ptrReg))
        }
        guard case .ptr(_, let offset) = ptrAtom.value else {
            return .error(.typeError("pGetOff requires pointer"))
        }
        guard let (resultLabel, newPC) = rules.pGetOffRule(ptrAtom.label, s.pcLabel) else {
            return .error(.securityViolation("pGetOff"))
        }
        s.registers[dstReg] = Atom(.int(offset), resultLabel ?? ptrAtom.label)
        s.pcLabel = newPC
        s.pc += 1

    // PSetOff r1 r2 r3: r3 := ptr(block(r1), r2), << TRUE, JOIN Lab1 Lab2, LabPC >>
    // r1 must contain Vptr, r2 must be Vint. Creates new ptr with same block, new offset.
    case .pSetOff(let ptrReg, let offReg, let dstReg):
        guard let ptrAtom = validReg(ptrReg, s),
              let offAtom = validReg(offReg, s),
              let _ = validReg(dstReg, s) else {
            return .error(.invalidRegister(ptrReg))
        }
        guard case .ptr(let block, _) = ptrAtom.value else {
            return .error(.typeError("pSetOff requires pointer in r1"))
        }
        guard case .int(let newOffset) = offAtom.value else {
            return .error(.typeError("pSetOff requires integer offset in r2"))
        }
        guard let (resultLabel, newPC) = rules.pSetOffRule(ptrAtom.label, offAtom.label, s.pcLabel) else {
            return .error(.securityViolation("pSetOff"))
        }
        s.registers[dstReg] = Atom(.ptr(block: block, offset: newOffset), resultLabel ?? ptrAtom.label.join(offAtom.label))
        s.pcLabel = newPC
        s.pc += 1

    // MSize r1 r2: r2 := size(frame(r1)), << TRUE, Lab2, JOIN LabPC Lab1 >>
    // r1 must contain Vptr. Lab1=ptrLabel, Lab2=frameLabel. Returns frame size as Vint.
    case .mSize(let ptrReg, let dstReg):
        guard let ptrAtom = validReg(ptrReg, s), let _ = validReg(dstReg, s) else {
            return .error(.invalidRegister(ptrReg))
        }
        guard case .ptr(let block, _) = ptrAtom.value,
              block >= 0, block < s.frames.count else {
            return .error(.invalidPointer)
        }
        let frameLabel = s.frames[block].label
        let size = s.frames[block].contents.count
        guard let (resultLabel, newPC) = rules.mSizeRule(ptrAtom.label, frameLabel, s.pcLabel) else {
            return .error(.securityViolation("mSize"))
        }
        s.registers[dstReg] = Atom(.int(size), resultLabel ?? frameLabel)
        s.pcLabel = newPC
        s.pc += 1

    // MLab r1 r2: r2 := Vlab(frameLabel(r1)), << TRUE, Lab1, LabPC >>
    // r1 must contain Vptr. Lab1=ptrLabel. Returns the frame label wrapped in Vlab.
    case .mLab(let ptrReg, let dstReg):
        guard let ptrAtom = validReg(ptrReg, s), let _ = validReg(dstReg, s) else {
            return .error(.invalidRegister(ptrReg))
        }
        guard case .ptr(let block, _) = ptrAtom.value,
              block >= 0, block < s.frames.count else {
            return .error(.invalidPointer)
        }
        let frameLabel = s.frames[block].label
        guard let (resultLabel, newPC) = rules.mLabRule(ptrAtom.label, s.pcLabel) else {
            return .error(.securityViolation("mLab"))
        }
        s.registers[dstReg] = Atom(.label(frameLabel), resultLabel ?? ptrAtom.label)
        s.pcLabel = newPC
        s.pc += 1

    // Jump r: pc := r, << TRUE, __, JOIN LabPC Lab1 >>
    case .jump(let r):
        guard let atom = validReg(r, s) else { return .error(.invalidRegister(r)) }
        guard case .int(let target) = atom.value else {
            return .error(.typeError("jump requires integer target"))
        }
        guard target >= 0, target < s.instructions.count else {
            return .error(.pcOutOfBounds)
        }
        guard let (_, newPC) = rules.jumpRule(atom.label, s.pcLabel) else {
            return .error(.securityViolation("jump"))
        }
        s.pcLabel = newPC
        s.pc = target

    // BNZ n r: if r != 0 then pc += n else pc += 1, << TRUE, __, JOIN Lab1 LabPC >>
    case .bnz(let offset, let r):
        guard let atom = validReg(r, s) else { return .error(.invalidRegister(r)) }
        guard case .int(let val) = atom.value else {
            return .error(.typeError("bnz requires integer test"))
        }
        guard let (_, newPC) = rules.bnzRule(atom.label, s.pcLabel) else {
            return .error(.securityViolation("bnz"))
        }
        let nextPC = val == 0 ? s.pc + 1 : s.pc + offset
        guard nextPC >= 0, nextPC < s.instructions.count else {
            return .error(.pcOutOfBounds)
        }
        s.pcLabel = newPC
        s.pc = nextPC

    // BCall r1 r2 r3: call with target=r1, retBound=r2 (must be Vlab), resultReg=r3
    // << TRUE, JOIN Lab2 LabPC, JOIN Lab1 LabPC >>
    case .call(let targetReg, let retBoundReg, let resultReg):
        guard let targetAtom = validReg(targetReg, s),
              let retBoundAtom = validReg(retBoundReg, s),
              let _ = validReg(resultReg, s) else {
            return .error(.invalidRegister(targetReg))
        }
        guard case .int(let targetPC) = targetAtom.value else {
            return .error(.typeError("call requires integer target"))
        }
        guard targetPC >= 0, targetPC < s.instructions.count else {
            return .error(.pcOutOfBounds)
        }
        guard s.pc + 1 < s.instructions.count else {
            return .error(.pcOutOfBounds)
        }
        guard case .label(let retBound) = retBoundAtom.value else {
            return .error(.typeError("call r2 must be a label value"))
        }
        guard let (rl, newPC) = rules.callRule(targetAtom.label, retBoundAtom.label, s.pcLabel) else {
            return .error(.securityViolation("call"))
        }
        let frame = StackFrame(
            returnPC: s.pc + 1,
            returnPCLabel: rl ?? s.pcLabel,
            savedRegisters: s.registers,
            resultReg: resultReg,
            resultLabel: retBound
        )
        s.stack.append(frame)
        s.pcLabel = newPC
        s.pc = targetPC

    // BRet: pop frame, write return value into saved regs, restore
    // << LE (JOIN Lab1 LabPC) (JOIN Lab2 Lab3), Lab2, Lab3 >>
    case .ret:
        guard let frame = s.stack.popLast() else {
            return .error(.stackUnderflow)
        }
        guard let retValAtom = validReg(frame.resultReg, s) else {
            return .error(.invalidRegister(frame.resultReg))
        }
        guard let (rl, newPC) = rules.retRule(
            retValAtom.label,
            frame.resultLabel,
            frame.returnPCLabel,
            s.pcLabel
        ) else {
            return .error(.securityViolation("ret: return value label too high"))
        }
        var restoredRegs = frame.savedRegisters
        if frame.resultReg >= 0, frame.resultReg < restoredRegs.count {
            restoredRegs[frame.resultReg] = Atom(retValAtom.value, rl ?? frame.resultLabel)
        }
        s.registers = restoredRegs
        s.pcLabel = newPC
        s.pc = frame.returnPC

    // Lab r1 r2: r2 := Vlab(label(r1)), << TRUE, BOT, LabPC >>
    case .lab(let src, let dst):
        guard let srcAtom = validReg(src, s), let _ = validReg(dst, s) else {
            return .error(.invalidRegister(src))
        }
        guard let (rl, newPC) = rules.labRule(s.pcLabel) else {
            return .error(.securityViolation("lab"))
        }
        s.registers[dst] = Atom(.label(srcAtom.label), rl ?? .low)
        s.pcLabel = newPC
        s.pc += 1

    // PcLab r: r := Vlab(pcLabel), << TRUE, BOT, LabPC >>
    case .pcLab(let dst):
        guard let _ = validReg(dst, s) else { return .error(.invalidRegister(dst)) }
        guard let (rl, newPC) = rules.pcLabRule(s.pcLabel) else {
            return .error(.securityViolation("pcLab"))
        }
        s.registers[dst] = Atom(.label(s.pcLabel), rl ?? .low)
        s.pcLabel = newPC
        s.pc += 1

    // PutLab l r: r := Vlab l, << TRUE, BOT, LabPC >>
    case .putLab(let lab, let dst):
        guard let _ = validReg(dst, s) else { return .error(.invalidRegister(dst)) }
        guard let (rl, newPC) = rules.putLabRule(s.pcLabel) else {
            return .error(.securityViolation("putLab"))
        }
        s.registers[dst] = Atom(.label(lab), rl ?? .low)
        s.pcLabel = newPC
        s.pc += 1

    // Output r (extension)
    case .output(let r):
        guard let atom = validReg(r, s) else { return .error(.invalidRegister(r)) }
        guard let (_, newPC) = rules.outputRule(atom.label, s.pcLabel) else {
            return .error(.securityViolation("output"))
        }
        s.pcLabel = newPC
        s.pc += 1
    }

    guard s.pc >= 0, s.pc < s.instructions.count else {
        return .error(.pcOutOfBounds)
    }

    return .ok(s)
}

/// Run the machine for up to `maxSteps` steps.
public func run(_ state: MachineState, rules: RuleTable = .correct, maxSteps: Int = 1000) -> MachineState {
    var current = state
    for _ in 0..<maxSteps {
        switch step(current, rules: rules) {
        case .ok(let next):
            current = next
        case .halted(let final):
            return final
        case .error:
            return current
        }
    }
    return current
}

// MARK: - Helpers

private func validReg(_ r: Reg, _ s: MachineState) -> Atom? {
    guard r >= 0, r < s.registers.count else { return nil }
    return s.registers[r]
}

/// Evaluate a binary operation.
/// Matches the Coq `eval_binop` function.
private func evalBinOp(_ op: BinOp, _ v1: Value, _ v2: Value) -> Value? {
    switch (op, v1, v2) {
    case (.add, .int(let a), .int(let b)):
        return .int(a &+ b)
    case (.mult, .int(let a), .int(let b)):
        return .int(a &* b)
    case (.eq, _, _):
        return .int(v1 == v2 ? 1 : 0)
    case (.flowsTo, .label(let l1), .label(let l2)):
        return .int(l1.flowsTo(l2) ? 1 : 0)
    case (.join, .label(let l1), .label(let l2)):
        return .label(l1.join(l2))
    default:
        return nil
    }
}
