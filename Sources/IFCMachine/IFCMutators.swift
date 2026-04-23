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

//  Mutators for the IFC machine types, ported from QuickChick/IFC Generation.v.
//
//  The Coq generation strategy:
//  1. Generate initial frames (frameCount frames of frameSize cells)
//  2. Generate instruction list
//  3. Generate PC, registers, stack
//  4. Populate frames with random atoms
//  5. Create a variation by varying high-labeled components
//

import PropertyTestingKit

// MARK: - Constants (from Generation.v Module C)

private enum C {
    static let codeLen = 6
    static let noRegisters = MachineState.registerCount
    static let frameCount = MachineState.defaultFrameCount
    static let frameSize = MachineState.defaultFrameSize
}

// MARK: - MachineState Mutator

extension MachineState: MutatorProviding {
    public static var defaultMutator: Mutator<MachineState> {
        Mutator(
            seeds: generateSeeds(),
            mutate: { mutateMachineState($0) },
            generate: { rng in generateMachineState(rng: &rng) }
        )
    }

    private static func generateSeeds() -> [MachineState] {
        var rng = FastRNG()
        return (0..<10).map { _ in generateMachineState(rng: &rng) }
    }
}

// MARK: - Variation Mutator

extension Variation: MutatorProviding {
    public static var defaultMutator: Mutator<Variation> {
        Mutator(
            seeds: generateSeeds(),
            mutate: { mutateVariation($0) },
            generate: { rng in generateVariation(rng: &rng) }
        )
    }

    private static func generateSeeds() -> [Variation] {
        var rng = FastRNG()
        return (0..<10).map { _ in generateVariation(rng: &rng) }
    }
}

// MARK: - State Generation

/// Generate a random well-formed machine state.
///
/// Follows gen_variation_state from Generation.v:
/// 1. Generate frames and registers
/// 2. Create state with placeholder instructions
/// 3. Call instantiateInstructions to fill imem with a single type-compatible instruction
private func generateMachineState(rng: inout FastRNG) -> MachineState {
    let frames = generateFrames(rng: &rng)
    let registers = generateRegisters(rng: &rng)
    let pc = Int.random(in: 0..<C.codeLen, using: &rng)
    let pcLabel = randomLabel(rng: &rng)

    let stack: [StackFrame]
    if Int.random(in: 0..<10, using: &rng) > 0 {
        stack = [generateStackFrame(instrCount: C.codeLen, rng: &rng)]
    } else {
        stack = []
    }

    let state = MachineState(
        instructions: Array(repeating: .nop, count: C.codeLen),
        frames: frames,
        registers: registers,
        stack: stack,
        pc: pc,
        pcLabel: pcLabel
    )
    return instantiateInstructions(state, rng: &rng)
}

/// Generate a Variation: two indistinguishable states.
///
/// From Generation.v gen_vary_state:
/// - If PC is low: vary high-labeled registers and memory, keep low values the same
/// - If PC is high: vary everything including PC, registers, but keep memory similar
private func generateVariation(rng: inout FastRNG) -> Variation {
    let obs = randomLabel(rng: &rng)
    let st1 = generateMachineState(rng: &rng)
    let st2 = varyState(st1, observer: obs, rng: &rng)
    return Variation(observer: obs, state1: st1, state2: st2)
}

/// Create a varied copy of a state that is indistinguishable at `obs` level.
///
/// Matches gen_vary_state + gen_var_frame + gen_vary_stack_loc from Generation.v.
///
/// REGISTERS (LOW-PC case): gen_vary_atom keeps the label and varies the value
/// within the same value type. For HIGH atoms we call varyAtom.
///
/// REGISTERS (HIGH-PC case): fully re-randomized (any type, any label).
///
/// MEMORY: gen_var_frame —
///   - HIGH-label frames: vary content AND size (choose len or len+1).
///   - LOW-label frames: apply gen_vary_atom to each cell: HIGH-labeled cells
///     get their values varied (type-preserving), LOW-labeled cells stay unchanged.
///     This is critical for detecting bugs like loadDropsResult.
///
/// STACK: gen_vary_stack_loc for each frame —
///   - LOW-returnPC frames: vary HIGH-labeled savedRegisters via varyAtom.
///   - HIGH-returnPC frames: regenerate entirely (savedRegisters, returnPC, etc.),
///     keeping returnPCLabel HIGH. This is critical for detecting retDropsPC.
///
/// Stamp vs. label: alloc sets stamp = JOIN(sizeLabel, labLabel, pcLabel).
/// Under HIGH PC, stamp = HIGH → frame invisible. Initial frames have stamp=LOW.
private func varyState(_ state: MachineState, observer obs: Label, rng: inout FastRNG) -> MachineState {
    var s = state

    if state.pcLabel.flowsTo(obs) {
        // PC is low: vary HIGH-labeled registers, memory, and stack.
        for i in s.registers.indices where !s.registers[i].label.flowsTo(obs) {
            s.registers[i] = varyAtom(s.registers[i], rng: &rng)
        }
        s.frames = varyFrames(s.frames, observer: obs, rng: &rng)
        s.stack = varyStack(s.stack, observer: obs, instrCount: state.instructions.count, rng: &rng)
    } else {
        // PC is high: vary everything.
        s.pc = Int.random(in: 0..<state.instructions.count, using: &rng)
        s.pcLabel = randomHighLabel(observer: obs, rng: &rng)
        for i in s.registers.indices {
            s.registers[i] = randomAtom(rng: &rng)
        }
        s.frames = varyFrames(s.frames, observer: obs, rng: &rng)
        s.stack = varyStack(s.stack, observer: obs, instrCount: state.instructions.count, rng: &rng)
    }

    return s
}

/// Apply gen_var_frame to every frame.
///
/// - HIGH-label frames: random content, possibly size+1 (indistFrame ignores content/size for HIGH).
/// - LOW-label frames: apply gen_vary_atom to each cell — vary HIGH-labeled cells,
///   keep LOW-labeled cells unchanged.
private func varyFrames(_ frames: [Frame], observer obs: Label, rng: inout FastRNG) -> [Frame] {
    var result = frames
    for fi in result.indices {
        if !result[fi].label.flowsTo(obs) {
            // HIGH-label frame: random content, possibly size+1
            let newSize = result[fi].contents.count + Int.random(in: 0...1, using: &rng)
            result[fi].contents = (0..<newSize).map { _ in randomAtom(rng: &rng) }
        } else {
            // LOW-label frame: vary HIGH-labeled cells, keep LOW-labeled cells
            for ci in result[fi].contents.indices where !result[fi].contents[ci].label.flowsTo(obs) {
                result[fi].contents[ci] = varyAtom(result[fi].contents[ci], rng: &rng)
            }
        }
    }
    return result
}

/// Apply gen_vary_stack_loc to every stack frame.
///
/// - LOW-returnPC frames: vary HIGH-labeled savedRegisters via varyAtom.
/// - HIGH-returnPC frames: regenerate entirely, keeping returnPCLabel HIGH.
private func varyStack(
    _ stack: [StackFrame],
    observer obs: Label,
    instrCount: Int,
    rng: inout FastRNG
) -> [StackFrame] {
    return stack.map { sf in
        if sf.returnPCLabel.flowsTo(obs) {
            // LOW returnPC: vary HIGH-labeled saved registers
            var varied = sf
            for i in varied.savedRegisters.indices where !varied.savedRegisters[i].label.flowsTo(obs) {
                varied.savedRegisters[i] = varyAtom(varied.savedRegisters[i], rng: &rng)
            }
            return varied
        } else {
            // HIGH returnPC: regenerate entirely, returnPCLabel stays HIGH
            return StackFrame(
                returnPC: Int.random(in: 0..<max(1, instrCount), using: &rng),
                returnPCLabel: randomHighLabel(observer: obs, rng: &rng),
                savedRegisters: (0..<C.noRegisters).map { _ in randomAtom(rng: &rng) },
                resultReg: Int.random(in: 0..<C.noRegisters, using: &rng),
                resultLabel: randomLabel(rng: &rng)
            )
        }
    }
}

// MARK: - Mutation

/// Mutate a machine state by making small changes.
private func mutateMachineState(_ state: MachineState) -> [MachineState] {
    var rng = FastRNG()
    var mutations: [MachineState] = []
    mutations.reserveCapacity(8)

    // Mutate a random register value
    var s1 = state
    let regIdx = Int.random(in: 0..<s1.registers.count, using: &rng)
    s1.registers[regIdx] = nudgeAtom(s1.registers[regIdx], rng: &rng)
    mutations.append(s1)

    // Mutate a random frame cell
    var s2 = state
    if !s2.frames.isEmpty {
        let frameIdx = Int.random(in: 0..<s2.frames.count, using: &rng)
        if !s2.frames[frameIdx].contents.isEmpty {
            let cellIdx = Int.random(in: 0..<s2.frames[frameIdx].contents.count, using: &rng)
            s2.frames[frameIdx].contents[cellIdx] = nudgeAtom(s2.frames[frameIdx].contents[cellIdx], rng: &rng)
        }
    }
    mutations.append(s2)

    // Flip a label in a register
    var s3 = state
    let regIdx3 = Int.random(in: 0..<s3.registers.count, using: &rng)
    s3.registers[regIdx3] = flipLabel(s3.registers[regIdx3])
    mutations.append(s3)

    // Flip a frame label
    var s4 = state
    if !s4.frames.isEmpty {
        let frameIdx = Int.random(in: 0..<s4.frames.count, using: &rng)
        s4.frames[frameIdx].label = s4.frames[frameIdx].label == .low ? .high : .low
    }
    mutations.append(s4)

    // Change PC
    var s5 = state
    s5.pc = Int.random(in: 0..<max(1, state.instructions.count), using: &rng)
    mutations.append(s5)

    // Flip PC label
    var s6 = state
    s6.pcLabel = s6.pcLabel == .low ? .high : .low
    mutations.append(s6)

    // Mutate an instruction
    var s7 = state
    if !s7.instructions.isEmpty {
        let instrIdx = Int.random(in: 0..<s7.instructions.count, using: &rng)
        s7.instructions[instrIdx] = randomInstruction(rng: &rng)
    }
    mutations.append(s7)

    return mutations
}

/// Mutate a Variation by applying all single-field mutations to state1 and re-deriving state2.
private func mutateVariation(_ v: Variation) -> [Variation] {
    var rng = FastRNG()
    var mutations: [Variation] = []
    mutations.reserveCapacity(8)

    for mutatedState in mutateMachineState(v.state1) {
        let varied = varyState(mutatedState, observer: v.observer, rng: &rng)
        mutations.append(Variation(observer: v.observer, state1: mutatedState, state2: varied))
    }

    // Flip observer
    let newObs: Label = v.observer == .low ? .high : .low
    let revaried = varyState(v.state1, observer: newObs, rng: &rng)
    mutations.append(Variation(observer: newObs, state1: v.state1, state2: revaried))

    return mutations
}

// MARK: - Primitive Generators

/// From Generation.v: gen_label
private func randomLabel(rng: inout FastRNG) -> Label {
    Bool.random(using: &rng) ? .low : .high
}

/// Generate a label strictly above the observer.
private func randomHighLabel(observer: Label, rng: inout FastRNG) -> Label {
    switch observer {
    case .low: return .high
    case .high: return .high
    }
}

/// From Generation.v: gen_atom = liftGen2 Atm (smart_gen inf) (smart_gen inf)
private func randomAtom(rng: inout FastRNG) -> Atom {
    Atom(randomValue(rng: &rng), randomLabel(rng: &rng))
}

/// From Generation.v: gen_value — frequency weighted: int, ptr, label
private func randomValue(rng: inout FastRNG) -> Value {
    let choice = Int.random(in: 0..<3, using: &rng)
    switch choice {
    case 0:
        let subChoice = Int.random(in: 0..<3, using: &rng)
        switch subChoice {
        case 0: return .int(0)
        case 1: return .int(Int.random(in: -100...100, using: &rng))
        default: return .int(Int.random(in: 0..<C.codeLen, using: &rng))
        }
    case 1:
        return .ptr(
            block: Int.random(in: 0..<C.frameCount, using: &rng),
            offset: Int.random(in: 0..<C.frameSize, using: &rng)
        )
    default:
        return .label(randomLabel(rng: &rng))
    }
}

/// Vary a HIGH atom's value within the same type, keeping its label.
///
/// Ported from gen_vary_atom in Generation.v (the 90% type-preserving branch).
/// Used in varyState LOW-PC case to keep HIGH registers compatible with the
/// ainstrSSNI-generated instruction (e.g. a Vptr register stays Vptr).
private func varyAtom(_ atom: Atom, rng: inout FastRNG) -> Atom {
    switch atom.value {
    case .int:
        return Atom(.int(Int.random(in: -100...100, using: &rng)), atom.label)
    case .ptr:
        return Atom(.ptr(block: Int.random(in: 0..<C.frameCount, using: &rng),
                         offset: Int.random(in: 0..<C.frameSize, using: &rng)),
                    atom.label)
    case .label:
        return Atom(.label(randomLabel(rng: &rng)), atom.label)
    }
}

/// Nudge an atom's value by a small amount.
private func nudgeAtom(_ atom: Atom, rng: inout FastRNG) -> Atom {
    switch atom.value {
    case .int(let n):
        let delta = Int.random(in: -3...3, using: &rng)
        return Atom(.int(n &+ delta), atom.label)
    case .ptr(let block, let offset):
        let newBlock = max(0, min(C.frameCount - 1, block + Int.random(in: -1...1, using: &rng)))
        let newOffset = max(0, min(C.frameSize - 1, offset + Int.random(in: -1...1, using: &rng)))
        return Atom(.ptr(block: newBlock, offset: newOffset), atom.label)
    case .label(let l):
        return Atom(.label(l == .low ? .high : .low), atom.label)
    }
}

/// Flip the security label of an atom.
private func flipLabel(_ atom: Atom) -> Atom {
    Atom(atom.value, atom.label == .low ? .high : .low)
}

// MARK: - Instruction Generation

/// Weighted instruction generation covering all opcodes.
/// Used in mutation path (mutateMachineState).
private func randomInstruction(rng: inout FastRNG) -> Instruction {
    let regs = C.noRegisters
    let choice = Int.random(in: 0..<20, using: &rng)
    let r1 = Int.random(in: 0..<regs, using: &rng)
    let r2 = Int.random(in: 0..<regs, using: &rng)
    let r3 = Int.random(in: 0..<regs, using: &rng)
    let n = Int.random(in: -10...10, using: &rng)

    switch choice {
    case 0:  return .put(n, r1)
    case 1:  return .mov(r1, r2)
    case 2:  return .binOp(BinOp.allCases[Int.random(in: 0..<BinOp.allCases.count, using: &rng)], r1, r2, r3)
    case 3:  return .load(r1, r2)
    case 4:  return .store(r1, r2)
    case 5:  return .write(r1, r2)
    case 6:  return .alloc(r1, r2, r3)
    case 7:  return .pGetOff(r1, r2)
    case 8:  return .pSetOff(r1, r2, r3)
    case 9:  return .mSize(r1, r2)
    case 10: return .mLab(r1, r2)
    case 11: return .jump(r1)
    case 12: return .bnz(Int.random(in: -2...3, using: &rng), r1)
    case 13: return .call(r1, r2, r3)
    case 14: return .ret
    case 15: return .lab(r1, r2)
    case 16: return .pcLab(r1)
    case 17: return .putLab(randomLabel(rng: &rng), r1)
    case 18: return .nop
    default: return .halt
    }
}

/// Weighted instruction generation compatible with the current register state.
///
/// Ported from ainstrSSNI in Generation.v. Groups registers by value type
/// (dptr, cptr, num, lab) and generates an instruction whose argument types
/// match the available registers — maximising the fraction of steps that succeed.
///
/// Weights match ainstrSSNI: Alloc=200 (highest), Store/Write=100, Ret=50
/// (when stack non-empty), everything else=10, Halt=0.
private func ainstrSSNI(_ state: MachineState, rng: inout FastRNG) -> Instruction {
    let regs = state.registers.count

    var dptr: [Int] = []   // registers holding Vptr
    var cptr: [Int] = []   // registers holding Vint in valid code range
    var num:  [Int] = []   // registers holding Vint
    var lab:  [Int] = []   // registers holding Vlab

    for (i, reg) in state.registers.enumerated() {
        switch reg.value {
        case .int(let n):
            num.append(i)
            if n >= 0 && n < state.instructions.count { cptr.append(i) }
        case .ptr:
            dptr.append(i)
        case .label:
            lab.append(i)
        }
    }

    let wNop     = 1
    let wPcLab   = 10
    let wLab     = 10
    let wMLab    = dptr.isEmpty ? 0 : 10
    let wPutLab  = 10
    let wCall    = (!cptr.isEmpty && !lab.isEmpty) ? 10 : 0
    let wRet     = state.stack.isEmpty ? 0 : 50
    let wAlloc   = (!num.isEmpty && !lab.isEmpty) ? 200 : 0
    let wLoad    = dptr.isEmpty ? 0 : 10
    let wStore   = dptr.isEmpty ? 0 : 100
    let wWrite   = dptr.isEmpty ? 0 : 100
    let wJump    = cptr.isEmpty ? 0 : 10
    let wBnz     = num.isEmpty ? 0 : 10
    let wPSetOff = (!dptr.isEmpty && !num.isEmpty) ? 10 : 0
    let wPut     = 10
    let wBinOp   = num.isEmpty ? 0 : 10
    let wMSize   = dptr.isEmpty ? 0 : 10
    let wPGetOff = dptr.isEmpty ? 0 : 10
    let wMov     = 10

    let total = wNop + wPcLab + wLab + wMLab + wPutLab + wCall + wRet + wAlloc +
                wLoad + wStore + wWrite + wJump + wBnz + wPSetOff + wPut + wBinOp +
                wMSize + wPGetOff + wMov

    var r = Int.random(in: 0..<total, using: &rng)

    r -= wNop;     if r < 0 { return .nop }
    r -= wPcLab;   if r < 0 { return .pcLab(Int.random(in: 0..<regs, using: &rng)) }
    r -= wLab;     if r < 0 { return .lab(Int.random(in: 0..<regs, using: &rng), Int.random(in: 0..<regs, using: &rng)) }
    r -= wMLab;    if r < 0 { return .mLab(dptr[Int.random(in: 0..<dptr.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    r -= wPutLab;  if r < 0 { return .putLab(randomLabel(rng: &rng), Int.random(in: 0..<regs, using: &rng)) }
    r -= wCall;    if r < 0 { return .call(cptr[Int.random(in: 0..<cptr.count, using: &rng)], lab[Int.random(in: 0..<lab.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    r -= wRet;     if r < 0 { return .ret }
    r -= wAlloc;   if r < 0 { return .alloc(num[Int.random(in: 0..<num.count, using: &rng)], lab[Int.random(in: 0..<lab.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    r -= wLoad;    if r < 0 { return .load(dptr[Int.random(in: 0..<dptr.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    r -= wStore;   if r < 0 { return .store(dptr[Int.random(in: 0..<dptr.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    r -= wWrite;   if r < 0 { return .write(dptr[Int.random(in: 0..<dptr.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    r -= wJump;    if r < 0 { return .jump(cptr[Int.random(in: 0..<cptr.count, using: &rng)]) }
    r -= wBnz;     if r < 0 { return .bnz(Int.random(in: -1...2, using: &rng), num[Int.random(in: 0..<num.count, using: &rng)]) }
    r -= wPSetOff; if r < 0 { return .pSetOff(dptr[Int.random(in: 0..<dptr.count, using: &rng)], num[Int.random(in: 0..<num.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    r -= wPut;     if r < 0 { return .put(Int.random(in: -10...10, using: &rng), Int.random(in: 0..<regs, using: &rng)) }
    r -= wBinOp
    if r < 0 {
        let op = BinOp.allCases[Int.random(in: 0..<BinOp.allCases.count, using: &rng)]
        return .binOp(op, num[Int.random(in: 0..<num.count, using: &rng)], num[Int.random(in: 0..<num.count, using: &rng)], Int.random(in: 0..<regs, using: &rng))
    }
    r -= wMSize;   if r < 0 { return .mSize(dptr[Int.random(in: 0..<dptr.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    r -= wPGetOff; if r < 0 { return .pGetOff(dptr[Int.random(in: 0..<dptr.count, using: &rng)], Int.random(in: 0..<regs, using: &rng)) }
    return .mov(Int.random(in: 0..<regs, using: &rng), Int.random(in: 0..<regs, using: &rng))
}

/// Fill all instruction slots with a single compatible instruction.
///
/// Ported from instantiate_instructions in Generation.v:
///   `nseq (length im) instr`
/// All imem slots get the same instruction, so any PC value executes
/// a step compatible with the current register types.
private func instantiateInstructions(_ state: MachineState, rng: inout FastRNG) -> MachineState {
    var s = state
    let instr = ainstrSSNI(state, rng: &rng)
    s.instructions = Array(repeating: instr, count: state.instructions.count)
    return s
}

private func generateFrames(rng: inout FastRNG) -> [Frame] {
    // Initial frames get stamp = LOW (bot in Coq) — visible to all observers.
    // From Generation.v gen_init_mem: alloc frame_size lab bot (Vint Z0 @ bot) m
    (0..<C.frameCount).map { _ in
        Frame(
            label: randomLabel(rng: &rng),
            stamp: .low,
            contents: (0..<C.frameSize).map { _ in randomAtom(rng: &rng) }
        )
    }
}

private func generateRegisters(rng: inout FastRNG) -> [Atom] {
    (0..<C.noRegisters).map { _ in randomAtom(rng: &rng) }
}

private func generateStackFrame(instrCount: Int, rng: inout FastRNG) -> StackFrame {
    StackFrame(
        returnPC: Int.random(in: 0..<max(1, instrCount), using: &rng),
        returnPCLabel: randomLabel(rng: &rng),
        savedRegisters: (0..<C.noRegisters).map { _ in randomAtom(rng: &rng) },
        resultReg: Int.random(in: 0..<C.noRegisters, using: &rng),
        resultLabel: randomLabel(rng: &rng)
    )
}
