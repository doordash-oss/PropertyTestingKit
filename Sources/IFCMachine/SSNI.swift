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

//  Step-sensitive noninterference (SSNI) property helpers.
//  Ported from QuickChick/IFC SSNI.v and SanityChecks.v.
//

// MARK: - Variation

/// A variation: two states that should be indistinguishable at `observer` level.
///
/// From Coq: Variation = Var (lab : Label) (st1 st2 : State)
public struct Variation: Sendable, Codable, Hashable {
    public var observer: Label
    public var state1: MachineState
    public var state2: MachineState

    public init(observer: Label, state1: MachineState, state2: MachineState) {
        self.observer = observer
        self.state1 = state1
        self.state2 = state2
    }
}

// MARK: - Well-Formedness

/// Check if a machine state is well-formed.
///
/// Ported from Reachability.v `well_formed`:
///   all (well_formed_label st) elems
///
/// well_formed_label st obs: all frames reachable at obs must have stamp ≤ obs.
/// For our 2-label lattice the HIGH case is trivially satisfied, so we only
/// check the LOW observer: every frame reachable at LOW level must have LOW stamp.
/// This detects alloc bugs that produce a LOW-labeled pointer to a HIGH-stamped frame.
///
/// Pointer offset validity is NOT checked — pSetOff can create out-of-bounds
/// offsets that become valid after a subsequent alloc.
public func wellFormed(_ state: MachineState) -> Bool {
    guard state.pc >= 0, state.pc < state.instructions.count else { return false }
    guard state.registers.count == MachineState.registerCount else { return false }

    for sf in state.stack {
        guard sf.resultReg >= 0, sf.resultReg < MachineState.registerCount else { return false }
        guard sf.returnPC >= 0, sf.returnPC < state.instructions.count else { return false }
        guard sf.savedRegisters.count == MachineState.registerCount else { return false }
    }

    return stampConsistentLow(state)
}

/// Check stamp consistency for observer=LOW.
///
/// Ported from Reachability.v `well_formed_label` / `reachable`:
///   Root set: LOW-labeled ptr registers when PC is LOW, plus LOW-labeled ptr
///   savedRegisters from stack frames with LOW returnPCLabel.
///   Transitively: LOW-labeled ptrs in LOW-label frame contents.
///   Invariant: every reachable frame must have LOW stamp.
private func stampConsistentLow(_ state: MachineState) -> Bool {
    var worklist: [Int] = []

    // Root set: LOW-labeled ptr registers when PC is LOW.
    if state.pcLabel.flowsTo(.low) {
        for reg in state.registers {
            if case .ptr(let block, _) = reg.value, reg.label.flowsTo(.low),
               block >= 0, block < state.frames.count {
                worklist.append(block)
            }
        }
    }

    // Root set: stack frames with LOW returnPCLabel contribute their LOW-ptr savedRegisters.
    for sf in state.stack where sf.returnPCLabel.flowsTo(.low) {
        for reg in sf.savedRegisters {
            if case .ptr(let block, _) = reg.value, reg.label.flowsTo(.low),
               block >= 0, block < state.frames.count {
                worklist.append(block)
            }
        }
    }

    var visited = Set<Int>()
    while !worklist.isEmpty {
        let block = worklist.removeLast()
        guard !visited.contains(block) else { continue }
        visited.insert(block)
        guard block < state.frames.count else { continue }
        let frame = state.frames[block]

        // Invariant: reachable frame must have LOW stamp.
        guard frame.stamp.flowsTo(.low) else { return false }

        // Transitively reachable via LOW-labeled ptrs in LOW-label frame contents.
        if frame.label.flowsTo(.low) {
            for atom in frame.contents {
                if case .ptr(let next, _) = atom.value, atom.label.flowsTo(.low),
                   next >= 0, next < state.frames.count, !visited.contains(next) {
                    worklist.append(next)
                }
            }
        }
    }

    return true
}

// MARK: - SSNI Property

/// Core SSNI property checker. Returns nil if no violation, or a description of the violation.
///
/// Direct port of propSSNI_helper from SSNI.v.
public func propSSNIHelper(table: RuleTable, variation: Variation) -> String? {
    let obs = variation.observer
    let st1 = variation.state1
    let st2 = variation.state2

    // varyState guarantees indistinguishable pairs by construction;
    // this assert is disabled by -O in all optimized test builds.
    assert(indistinguishable(st1, st2, observer: obs), "varyState produced non-indistinguishable pair")

    let r1 = step(st1, rules: table)
    guard case .ok(let st1Prime) = r1 else { return nil }

    let st1Low = st1.pcLabel.flowsTo(obs)

    if st1Low {
        let r2 = step(st2, rules: table)
        guard case .ok(let st2Prime) = r2 else { return nil }
        if !indistinguishable(st1Prime, st2Prime, observer: obs) {
            return "LOW -> *: states diverge after step at pc=\(st1.pc)"
        }
    } else {
        let st1PrimeLow = st1Prime.pcLabel.flowsTo(obs)
        if st1PrimeLow {
            let r2 = step(st2, rules: table)
            guard case .ok(let st2Prime) = r2 else { return nil }
            let st2PrimeLow = st2Prime.pcLabel.flowsTo(obs)
            if st2PrimeLow {
                if !indistinguishable(st1Prime, st2Prime, observer: obs) {
                    return "HIGH -> LOW: states diverge after step at pc=\(st1.pc)"
                }
            }
        } else {
            if !indistinguishable(st1, st1Prime, observer: obs) {
                return "HIGH -> HIGH: state changed observably after high step at pc=\(st1.pc)"
            }
        }
    }

    return nil
}
