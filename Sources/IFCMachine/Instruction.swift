//
//  Instruction.swift
//  IFCMachine
//
//  The instruction set for the IFC register machine.
//  Ported from QuickChick/IFC Instructions.v.
//

/// Register index.
public typealias Reg = Int

/// Binary operations.
public enum BinOp: Sendable, Codable, Hashable, CaseIterable {
    case add
    case mult
    case eq
    case join
    case flowsTo
}

/// Machine instructions.
///
/// Full port of the Coq `Instr` inductive type, including frame-memory instructions.
public enum Instruction: Sendable, Codable, Hashable {
    // Data movement
    case put(Int, Reg)                    // Put n r: r := Vint n
    case mov(Reg, Reg)                    // Mov r1 r2: r2 := r1
    case binOp(BinOp, Reg, Reg, Reg)      // BinOp o r1 r2 r3: r3 := r1 op r2

    // Memory (ptr-based)
    case load(Reg, Reg)                   // Load r1 r2: r2 := mem[r1] (r1 = Vptr)
    case store(Reg, Reg)                  // Store r1 r2: mem[r1] := r2 (r1 = Vptr)
    case write(Reg, Reg)                  // Write r1 r2: strong-update mem[r1] := r2

    // Frame allocation and pointer arithmetic
    case alloc(Reg, Reg, Reg)             // Alloc r1 r2 r3: r3 := alloc(size=r1, label=r2)
    case pGetOff(Reg, Reg)                // PGetOff r1 r2: r2 := offset(r1)
    case pSetOff(Reg, Reg, Reg)           // PSetOff r1 r2 r3: r3 := ptr(block(r1), r2)
    case mSize(Reg, Reg)                  // MSize r1 r2: r2 := size(frame(r1))
    case mLab(Reg, Reg)                   // MLab r1 r2: r2 := Vlab(frameLabel(r1))

    // Control flow
    case jump(Reg)                        // Jump r: pc := r
    case bnz(Int, Reg)                    // BNZ n r: if r != 0 then pc += n else pc += 1
    case call(Reg, Reg, Reg)              // BCall r1 r2 r3: call target=r1, retLabel=r2, resultReg=r3
    case ret                              // BRet: return

    // Label operations
    case lab(Reg, Reg)                    // Lab r1 r2: r2 := Vlab(label(r1))
    case pcLab(Reg)                       // PcLab r: r := Vlab(pcLabel)
    case putLab(Label, Reg)               // PutLab l r: r := Vlab l

    // Output — not in the original IFC machine but useful for testing
    case output(Reg)

    // Control
    case nop
    case halt
}
