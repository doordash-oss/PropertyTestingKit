//
//  RuleTable.swift
//  IFCMachine
//
//  Label propagation rules for the IFC machine.
//  Ported from QuickChick/IFC Machine.v default_table.
//
//  Each rule returns (resultLabel?, newPCLabel).
//  If the rule's side condition fails, the step is blocked (security violation).
//
//  The Coq notation:
//    << TRUE , Lab1 , LabPC >>  means allow=TRUE, result=Lab1, newPC=LabPC
//    << LE (JOIN Lab1 LabPC) Lab2 , Lab3 , LabPC >>  means check flowsTo, then result=Lab3, newPC=LabPC
//

/// Result of applying a rule: an optional result label and a new PC label.
/// `nil` means the rule's side condition failed (security violation).
public typealias RuleResult = (resultLabel: Label?, newPCLabel: Label)?

/// Rule table for label propagation.
///
/// Each closure takes the relevant labels and returns `RuleResult`.
/// The default implementation matches the Coq `default_table` exactly.
public struct RuleTable: Sendable {

    /// Nop: << TRUE, __, LabPC >> — no result, PC unchanged.
    public var nopRule: @Sendable (_ pc: Label) -> RuleResult

    /// Put: << TRUE, BOT, LabPC >> — result label is bot, PC unchanged.
    public var putRule: @Sendable (_ pc: Label) -> RuleResult

    /// Mov r1 r2: << TRUE, Lab1, LabPC >> — result = source label, PC unchanged.
    public var movRule: @Sendable (_ srcLabel: Label, _ pc: Label) -> RuleResult

    /// BinOp: << TRUE, JOIN Lab1 Lab2, LabPC >> — result = join of operand labels, PC unchanged.
    public var binOpRule: @Sendable (_ lhs: Label, _ rhs: Label, _ pc: Label) -> RuleResult

    /// Load r1 r2: << TRUE, Lab3, JOIN LabPC (JOIN Lab1 Lab2) >>
    /// Labels: Lab1=ptrLabel, Lab2=frameLabelOfPtr, Lab3=memValueLabel
    /// Result = memValueLabel, newPC = join(pc, join(ptr, frameLabel))
    public var loadRule: @Sendable (_ ptrLabel: Label, _ frameLabel: Label, _ memValueLabel: Label, _ pc: Label) -> RuleResult

    /// Store r1 r2: << LE (JOIN Lab1 LabPC) Lab2, Lab3, LabPC >>
    /// Labels: Lab1=ptrLabel, Lab2=frameLabel, Lab3=valueLabel
    /// Side condition: join(ptrLabel, pc) flowsTo frameLabel
    /// Result = valueLabel, PC unchanged.
    public var storeRule: @Sendable (_ ptrLabel: Label, _ frameLabel: Label, _ valueLabel: Label, _ pc: Label) -> RuleResult

    /// Write r1 r2: << LE (JOIN (JOIN LabPC Lab1) Lab3) (JOIN Lab2 Lab4), Lab4, LabPC >>
    /// Labels: Lab1=ptrLabel, Lab2=frameLabel, Lab3=valueLabel, Lab4=cellLabel
    /// Side condition: join(join(pc, ptr), val) flowsTo join(frame, cell)
    /// Result = cellLabel, PC unchanged.
    public var writeRule: @Sendable (_ ptrLabel: Label, _ frameLabel: Label, _ valueLabel: Label, _ cellLabel: Label, _ pc: Label) -> RuleResult

    /// Jump: << TRUE, __, JOIN LabPC Lab1 >> — no result label, newPC = join(pc, targetLabel).
    public var jumpRule: @Sendable (_ targetLabel: Label, _ pc: Label) -> RuleResult

    /// BNZ: << TRUE, __, JOIN Lab1 LabPC >> — no result label, newPC = join(testLabel, pc).
    public var bnzRule: @Sendable (_ testLabel: Label, _ pc: Label) -> RuleResult

    /// BCall: << TRUE, JOIN Lab2 LabPC, JOIN Lab1 LabPC >>
    /// Labels: Lab1=targetAddrLabel, Lab2=retBoundLabel
    /// Result = join(retBound, pc), newPC = join(targetAddr, pc).
    public var callRule: @Sendable (_ targetLabel: Label, _ retBoundLabel: Label, _ pc: Label) -> RuleResult

    /// BRet: << LE (JOIN Lab1 LabPC) (JOIN Lab2 Lab3), Lab2, Lab3 >>
    /// Labels: Lab1=returnValueLabel, Lab2=savedRetBound, Lab3=savedPCLabel
    /// Side condition: join(retValLabel, pc) flowsTo join(savedRetBound, savedPCLabel)
    /// Result = savedRetBound, newPC = savedPCLabel.
    public var retRule: @Sendable (_ retValLabel: Label, _ savedRetBound: Label, _ savedPCLabel: Label, _ pc: Label) -> RuleResult

    /// Lab r1 r2: << TRUE, BOT, LabPC >> — result = bot, PC unchanged.
    public var labRule: @Sendable (_ pc: Label) -> RuleResult

    /// PcLab r: << TRUE, BOT, LabPC >> — result = bot, PC unchanged.
    public var pcLabRule: @Sendable (_ pc: Label) -> RuleResult

    /// PutLab l r: << TRUE, BOT, LabPC >> — result = bot, PC unchanged.
    public var putLabRule: @Sendable (_ pc: Label) -> RuleResult

    /// Alloc r1 r2 r3: << TRUE, JOIN Lab1 Lab2, LabPC >>
    /// Lab1 = sizeLabel, Lab2 = labLabel
    public var allocRule: @Sendable (_ sizeLabel: Label, _ labLabel: Label, _ pc: Label) -> RuleResult

    /// PGetOff r1 r2: << TRUE, Lab1, LabPC >>
    /// Lab1 = ptrLabel
    public var pGetOffRule: @Sendable (_ ptrLabel: Label, _ pc: Label) -> RuleResult

    /// PSetOff r1 r2 r3: << TRUE, JOIN Lab1 Lab2, LabPC >>
    /// Lab1 = ptrLabel, Lab2 = offsetLabel
    public var pSetOffRule: @Sendable (_ ptrLabel: Label, _ offLabel: Label, _ pc: Label) -> RuleResult

    /// MSize r1 r2: << TRUE, Lab2, JOIN LabPC Lab1 >>
    /// Lab1 = ptrLabel, Lab2 = frameLabel
    public var mSizeRule: @Sendable (_ ptrLabel: Label, _ frameLabel: Label, _ pc: Label) -> RuleResult

    /// MLab r1 r2: << TRUE, Lab1, LabPC >>
    /// Lab1 = ptrLabel
    public var mLabRule: @Sendable (_ ptrLabel: Label, _ pc: Label) -> RuleResult

    /// Output (not in original — uses join of reg label and PC).
    public var outputRule: @Sendable (_ regLabel: Label, _ pc: Label) -> RuleResult

    /// The correct rule table matching the Coq `default_table`.
    public static let correct = RuleTable(
        // Nop: << TRUE, __, LabPC >>
        nopRule: { pc in (resultLabel: nil, newPCLabel: pc) },

        // Put: << TRUE, BOT, LabPC >>
        putRule: { pc in (resultLabel: .low, newPCLabel: pc) },

        // Mov: << TRUE, Lab1, LabPC >>
        movRule: { src, pc in (resultLabel: src, newPCLabel: pc) },

        // BinOp: << TRUE, JOIN Lab1 Lab2, LabPC >>
        binOpRule: { lhs, rhs, pc in (resultLabel: lhs.join(rhs), newPCLabel: pc) },

        // Load: << TRUE, Lab3, JOIN LabPC (JOIN Lab1 Lab2) >>
        loadRule: { ptr, frame, memVal, pc in
            (resultLabel: memVal, newPCLabel: pc.join(ptr.join(frame)))
        },

        // Store: << LE (JOIN Lab1 LabPC) Lab2, Lab3, LabPC >>
        storeRule: { ptr, frame, val, pc in
            let check = ptr.join(pc)
            guard check.flowsTo(frame) else { return nil }
            return (resultLabel: val, newPCLabel: pc)
        },

        // Write: << LE (JOIN (JOIN LabPC Lab1) Lab3) (JOIN Lab2 Lab4), Lab4, LabPC >>
        writeRule: { ptr, frame, val, cell, pc in
            let check = pc.join(ptr).join(val)
            guard check.flowsTo(frame.join(cell)) else { return nil }
            return (resultLabel: cell, newPCLabel: pc)
        },

        // Jump: << TRUE, __, JOIN LabPC Lab1 >>
        jumpRule: { target, pc in (resultLabel: nil, newPCLabel: pc.join(target)) },

        // BNZ: << TRUE, __, JOIN Lab1 LabPC >>
        bnzRule: { test, pc in (resultLabel: nil, newPCLabel: test.join(pc)) },

        // BCall: << TRUE, JOIN Lab2 LabPC, JOIN Lab1 LabPC >>
        callRule: { target, retBound, pc in
            (resultLabel: retBound.join(pc), newPCLabel: target.join(pc))
        },

        // BRet: << LE (JOIN Lab1 LabPC) (JOIN Lab2 Lab3), Lab2, Lab3 >>
        retRule: { retVal, savedBound, savedPC, pc in
            let check = retVal.join(pc)
            let target = savedBound.join(savedPC)
            guard check.flowsTo(target) else { return nil }
            return (resultLabel: savedBound, newPCLabel: savedPC)
        },

        // Lab/PcLab/PutLab: << TRUE, BOT, LabPC >>
        labRule: { pc in (resultLabel: .low, newPCLabel: pc) },
        pcLabRule: { pc in (resultLabel: .low, newPCLabel: pc) },
        putLabRule: { pc in (resultLabel: .low, newPCLabel: pc) },

        // Alloc: << TRUE, JOIN Lab1 Lab2, LabPC >>
        allocRule: { size, lab, pc in (resultLabel: size.join(lab), newPCLabel: pc) },

        // PGetOff: << TRUE, Lab1, LabPC >>
        pGetOffRule: { ptr, pc in (resultLabel: ptr, newPCLabel: pc) },

        // PSetOff: << TRUE, JOIN Lab1 Lab2, LabPC >>
        pSetOffRule: { ptr, off, pc in (resultLabel: ptr.join(off), newPCLabel: pc) },

        // MSize: << TRUE, Lab2, JOIN LabPC Lab1 >>
        mSizeRule: { ptr, frame, pc in (resultLabel: frame, newPCLabel: pc.join(ptr)) },

        // MLab: << TRUE, Lab1, LabPC >>
        mLabRule: { ptr, pc in (resultLabel: ptr, newPCLabel: pc) },

        outputRule: { reg, pc in (resultLabel: reg.join(pc), newPCLabel: pc) }
    )
}
