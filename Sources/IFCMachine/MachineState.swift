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

//  The state of the IFC register machine.
//  Ported from QuickChick/IFC Machine.v.
//

/// A memory frame: a labeled block of atoms.
///
/// Matches the Coq `frame` record, extended with a stamp:
///   Frame { label : Label; stamp : Label; contents : list Atom }
///
/// - `label`: security level of frame contents — controls whether contents
///   are compared in `indistFrame` (HIGH label → contents are opaque).
/// - `stamp`: determines whether a frame is *visible* to an observer
///   in `indistMemory`. Set to `JOIN(sizeLabel, labLabel, pcLabel)` on alloc;
///   initial frames have stamp = LOW (visible to all observers).
public struct Frame: Sendable, Codable, Hashable {
    /// Security label for frame contents — controls content visibility.
    public var label: Label
    /// Stamp — determines observer visibility. Set by alloc to JOIN of contributing labels.
    public var stamp: Label
    /// Cell contents (atoms).
    public var contents: [Atom]

    public init(label: Label, stamp: Label = .low, contents: [Atom]) {
        self.label = label
        self.stamp = stamp
        self.contents = contents
    }
}

/// A stack frame saved during a function call.
///
/// Matches the Coq `StackFrame` record:
///   SF { sf_return_addr : Ptr_atom; sf_saved_regs : regSet;
///        sf_result_reg : regId; sf_result_lab : Label }
public struct StackFrame: Sendable, Codable, Hashable {
    /// Return address (instruction index).
    public var returnPC: Int
    /// PC label at the time of the call (return PC label).
    public var returnPCLabel: Label
    /// Saved register file at call time.
    public var savedRegisters: [Atom]
    /// Which register receives the return value.
    public var resultReg: Reg
    /// The label bound for the return value (from r2 of BCall).
    public var resultLabel: Label

    public init(returnPC: Int, returnPCLabel: Label, savedRegisters: [Atom], resultReg: Reg, resultLabel: Label) {
        self.returnPC = returnPC
        self.returnPCLabel = returnPCLabel
        self.savedRegisters = savedRegisters
        self.resultReg = resultReg
        self.resultLabel = resultLabel
    }
}

/// The complete state of the IFC machine.
///
/// Matches the Coq `State` record:
///   St { st_imem : imem; st_mem : memory; st_stack : Stack;
///        st_regs : regSet; st_pc : Ptr_atom }
public struct MachineState: Sendable, Codable, Hashable {
    /// Instruction memory (immutable program).
    public var instructions: [Instruction]

    /// Data memory: list of labeled frames, each containing a list of atoms.
    /// Pointers (block, offset) address into this structure.
    /// Alloc can append new frames at runtime.
    public var frames: [Frame]

    /// Register file: array of labeled atoms.
    public var registers: [Atom]

    /// Call stack.
    public var stack: [StackFrame]

    /// Program counter.
    public var pc: Int

    /// PC security label — tracks the security context of the current control flow.
    public var pcLabel: Label

    /// Whether the machine has halted.
    public var halted: Bool

    /// Number of registers.
    public static let registerCount = 8

    /// Default number of memory frames.
    public static let defaultFrameCount = 4

    /// Default number of cells per frame.
    public static let defaultFrameSize = 4

    public init(
        instructions: [Instruction],
        frames: [Frame]? = nil,
        registers: [Atom]? = nil,
        stack: [StackFrame] = [],
        pc: Int = 0,
        pcLabel: Label = .low,
        halted: Bool = false
    ) {
        self.instructions = instructions
        self.frames = frames ?? (0..<Self.defaultFrameCount).map { _ in
            Frame(label: .low, contents: Array(repeating: .int(0, .low), count: Self.defaultFrameSize))
        }
        self.registers = registers ?? Array(repeating: .int(0, .low), count: Self.registerCount)
        self.stack = stack
        self.pc = pc
        self.pcLabel = pcLabel
        self.halted = halted
    }

    /// Whether the PC is in a low (public) security context.
    public var isLowPC: Bool { pcLabel == .low }
}
