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
//  Indistinguishability.swift
//  IFCMachine
//
//  Low-equivalence (indistinguishability) relations for noninterference testing.
//  Ported from QuickChick/IFC Indist.v.
//
//  Two states are indistinguishable to an observer at level `obs` if they
//  agree on all values labeled at or below `obs`. Values above `obs` can differ.
//

/// Check if two atoms are indistinguishable at observer level `obs`.
///
/// From Coq: labels must match. If the label is above obs (high), values
/// can differ. If at or below obs (low), values must be equal.
public func indistAtom(_ a: Atom, _ b: Atom, observer obs: Label) -> Bool {
    guard a.label == b.label else { return false }
    if !a.label.flowsTo(obs) {
        return true  // above observer — values are opaque
    }
    return a.value == b.value
}

/// Check if two register files are indistinguishable.
public func indistRegisters(_ a: [Atom], _ b: [Atom], observer obs: Label) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).allSatisfy { indistAtom($0, $1, observer: obs) }
}

/// Check if two frames are indistinguishable.
///
/// From Coq `indistFrame`:
///   (l1 == l2) && (isHigh l1 obs || indist obs vs1 vs2)
///
/// Frame labels must be equal. If the label is above the observer (HIGH),
/// contents are opaque and need not match. Otherwise contents must match.
public func indistFrame(_ a: Frame, _ b: Frame, observer obs: Label) -> Bool {
    guard a.label == b.label else { return false }
    if !a.label.flowsTo(obs) { return true }  // HIGH label — contents opaque
    return indistRegisters(a.contents, b.contents, observer: obs)
}

/// Check if two frame memories are indistinguishable.
///
/// Ported from Coq `indistMem` in Indist.v, which uses `blocks_stamped_below`
/// (the block's *stamp*, not label) to determine visibility:
///
///   indistMemAsym lab m1 m2 =
///     ∀ b ∈ blocks_stamped_below lab m1, indist lab (m1[b]) (m2[b])
///
///   indistMem lab m1 m2 = indistMemAsym lab m1 m2 && indistMemAsym lab m2 m1
///
/// Key: frame STAMP controls observer visibility; frame LABEL controls
/// whether frame contents must match within a visible frame pair.
///
/// Alloc sets stamp = JOIN(sizeLabel, labLabel, pcLabel). Under HIGH PC,
/// stamp = HIGH → frame invisible → no SSNI violation even if label differs.
public func indistMemory(_ a: [Frame], _ b: [Frame], observer obs: Label) -> Bool {
    // indistMemAsym(a, b): for each frame in a with LOW stamp, compare with b[i]
    for i in a.indices where a[i].stamp.flowsTo(obs) {
        if i >= b.count { return false }  // a has a visible frame that b lacks
        if !indistFrame(a[i], b[i], observer: obs) { return false }
    }
    // indistMemAsym(b, a): for each frame in b with LOW stamp, compare with a[i]
    for i in b.indices where b[i].stamp.flowsTo(obs) {
        if i >= a.count { return false }  // b has a visible frame that a lacks
        if !indistFrame(a[i], b[i], observer: obs) { return false }
    }
    return true
}

/// Check if two stack frames are indistinguishable.
///
/// From Coq: if either return PC is low (visible), all fields must match.
/// If both return PCs are high, frames are indistinguishable.
public func indistStackFrame(_ a: StackFrame, _ b: StackFrame, observer obs: Label) -> Bool {
    let aLow = a.returnPCLabel.flowsTo(obs)
    let bLow = b.returnPCLabel.flowsTo(obs)

    if !aLow && !bLow { return true }

    return a.returnPC == b.returnPC
        && a.returnPCLabel == b.returnPCLabel
        && indistRegisters(a.savedRegisters, b.savedRegisters, observer: obs)
        && a.resultReg == b.resultReg
        && a.resultLabel == b.resultLabel
}

/// Drop high stack frames from the top of the stack.
///
/// From Coq `cropTop`: drops frames from the top (head of Coq list = end of Swift array)
/// until a frame with a low return PC is found.
public func cropTop(_ stack: [StackFrame], observer obs: Label) -> [StackFrame] {
    guard let lastLow = stack.lastIndex(where: { $0.returnPCLabel.flowsTo(obs) }) else {
        return []
    }
    return Array(stack[...lastLow])
}

/// Check if two stacks are indistinguishable.
public func indistStack(_ a: [StackFrame], _ b: [StackFrame], observer obs: Label) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).allSatisfy { indistStackFrame($0, $1, observer: obs) }
}

/// Check if two machine states are indistinguishable to an observer.
///
/// From Coq `indistState`:
/// 1. Instruction memories must be equal.
/// 2. Data memories must be indistinguishable (frame-by-frame).
/// 3. If either PC is low: PCs must be equal, stacks and registers must match.
/// 4. If both PCs are high: only the cropped stacks must be indistinguishable.
public func indistinguishable(_ a: MachineState, _ b: MachineState, observer obs: Label = .low) -> Bool {
    guard a.instructions == b.instructions else { return false }
    guard indistMemory(a.frames, b.frames, observer: obs) else { return false }

    let aLow = a.pcLabel.flowsTo(obs)
    let bLow = b.pcLabel.flowsTo(obs)

    if aLow || bLow {
        guard a.pc == b.pc else { return false }
        guard a.pcLabel == b.pcLabel else { return false }
        guard indistStack(a.stack, b.stack, observer: obs) else { return false }
        guard indistRegisters(a.registers, b.registers, observer: obs) else { return false }
        return true
    } else {
        let aCropped = cropTop(a.stack, observer: obs)
        let bCropped = cropTop(b.stack, observer: obs)
        return indistStack(aCropped, bCropped, observer: obs)
    }
}

// MARK: - SSNI (Single-Step Noninterference)

/// Check the three cases of SSNI.
///
/// Returns `nil` if the property holds, or a description of the violation.
public func checkSSNI(
    _ s1: MachineState,
    _ s2: MachineState,
    observer obs: Label = .low,
    rules: RuleTable = .correct
) -> String? {
    guard indistinguishable(s1, s2, observer: obs) else {
        return nil  // precondition not met
    }

    let r1 = step(s1, rules: rules)
    let r2 = step(s2, rules: rules)

    let s1Low = s1.pcLabel.flowsTo(obs)

    switch (r1, r2) {
    case (.ok(let next1), .ok(let next2)):
        let next1Low = next1.pcLabel.flowsTo(obs)
        let next2Low = next2.pcLabel.flowsTo(obs)

        if s1Low {
            if !indistinguishable(next1, next2, observer: obs) {
                return "SSNI LOW→* violation at pc=\(s1.pc)"
            }
        } else if next1Low && next2Low {
            if !indistinguishable(next1, next2, observer: obs) {
                return "SSNI HIGH→LOW violation at pc=\(s1.pc)"
            }
        } else if !next1Low && !next2Low {
            if !indistinguishable(s1, next1, observer: obs) {
                return "SSNI HIGH→HIGH violation: s1 diverged from itself"
            }
            if !indistinguishable(s2, next2, observer: obs) {
                return "SSNI HIGH→HIGH violation: s2 diverged from itself"
            }
        }
        return nil

    case (.halted(let next1), .halted(let next2)):
        if s1Low && !indistinguishable(next1, next2, observer: obs) {
            return "SSNI violation: halted states diverge"
        }
        return nil

    case (.error, .error):
        return nil

    case (.ok, .halted), (.halted, .ok):
        if s1Low {
            return "SSNI violation: different step outcomes (ok vs halted) at pc=\(s1.pc)"
        }
        return nil

    case (.ok, .error), (.error, .ok):
        if s1Low {
            return "SSNI violation: different step outcomes (ok vs error) at pc=\(s1.pc)"
        }
        return nil

    case (.halted, .error), (.error, .halted):
        if s1Low {
            return "SSNI violation: different step outcomes (halted vs error) at pc=\(s1.pc)"
        }
        return nil
    }
}
