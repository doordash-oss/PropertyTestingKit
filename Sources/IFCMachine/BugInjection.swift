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
//  BugInjection.swift
//  IFCMachine
//
//  Systematic bug injection for the IFC register machine.
//  Each bug corresponds to exactly one mutation from the paper's methodology
//  (Lampropoulos et al., OOPSLA 2019, §4.1.2): for each rule, drop one
//  atomic sub-condition from the check or one label from a join expression
//  in the result or PC.
//
//  The register machine has 33 mutations across 19 opcodes.
//

/// A catalog of injectable bugs.
///
/// Each case is one systematic rule-table mutation guaranteed to introduce
/// a noninterference violation.
public enum IFCBug: String, CaseIterable, Sendable {

    // MARK: - Mov: << TRUE, Lab1, LabPC >>
    // mutate_expr Lab1 → [BOT]: 1 result mutation
    case movDropsResult         // result = BOT

    // MARK: - BinOp: << TRUE, JOIN Lab1 Lab2, LabPC >>
    // mutate_expr (JOIN Lab1 Lab2) → [Lab2, Lab1]: 2 result mutations
    case binOpDropsLHS          // result = Lab2 (drops Lab1)
    case binOpDropsRHS          // result = Lab1 (drops Lab2)

    // MARK: - Load: << TRUE, Lab3, JOIN LabPC (JOIN Lab1 Lab2) >>
    // Lab1=ptrLabel, Lab2=frameLabel, Lab3=memValueLabel
    // mutate_expr Lab3 → [BOT]: 1 result mutation
    // mutate_pc: 2 PC mutations
    case loadDropsResult        // result = BOT
    case loadDropsPtrFromPC     // result = JOIN(memVal, ptr), PC = JOIN(LabPC, frame)
    case loadDropsFrameFromPC   // result = JOIN(memVal, frame), PC = JOIN(LabPC, ptr)

    // MARK: - Store: << LE (JOIN Lab1 LabPC) Lab2, Lab3, LabPC >>
    // Lab1=ptrLabel, Lab2=frameLabel, Lab3=valueLabel
    // mutate_scond: 2 check mutations
    // mutate_expr Lab3 → [BOT]: 1 result mutation
    case storeCheckDropsPtr     // check = LE LabPC Lab2 (drops ptr from check)
    case storeCheckDropsPC      // check = LE Lab1 Lab2 (drops pc from check)
    case storeDropsResult       // result = BOT

    // MARK: - Write: << LE (JOIN (JOIN LabPC Lab1) Lab3) (JOIN Lab2 Lab4), Lab4, LabPC >>
    // Lab1=ptrLabel, Lab2=frameLabel, Lab3=valueLabel, Lab4=cellLabel
    // mutate_scond: 3 check mutations (break_scond [LabPC, Lab1, Lab3])
    // mutate_expr Lab4 → [BOT]: 1 result mutation
    case writeCheckDropsPC      // check = LE (JOIN Lab1 Lab3) (JOIN Lab2 Lab4)
    case writeCheckDropsPtr     // check = LE (JOIN LabPC Lab3) (JOIN Lab2 Lab4)
    case writeCheckDropsValue   // check = LE (JOIN LabPC Lab1) (JOIN Lab2 Lab4)
    case writeDropsResult       // result = BOT

    // MARK: - Jump: << TRUE, __, JOIN LabPC Lab1 >>
    // result = None → mutate_pc None: 2 PC mutations
    case jumpDropsPC            // PC = Lab1 (drops LabPC from PC)
    case jumpDropsTargetLabel   // PC = LabPC (drops Lab1)

    // MARK: - BNZ: << TRUE, __, JOIN Lab1 LabPC >>
    // result = None → mutate_pc None: 2 PC mutations
    case bnzDropsTestLabel      // PC = LabPC (drops Lab1)
    case bnzDropsPC             // PC = Lab1 (drops LabPC from PC)

    // MARK: - BCall: << TRUE, JOIN Lab2 LabPC, JOIN Lab1 LabPC >>
    // Lab1=targetAddrLabel, Lab2=retBoundLabel
    // mutate_expr: 2 result mutations
    // mutate_pc: 1 PC mutation
    case callDropsRetBound      // result = LabPC (drops Lab2 from result)
    case callDropsPCFromResult  // result = Lab2 (drops LabPC from result)
    case callDropsTargetFromPC  // result = JOIN(Lab2,LabPC,Lab1), PC = LabPC (Lab1 moved to result)

    // MARK: - BRet: << LE (JOIN Lab1 LabPC) (JOIN Lab2 Lab3), Lab2, Lab3 >>
    // Lab1=retValLabel, Lab2=savedRetBound, Lab3=savedPCLabel
    // mutate_scond: 2 check mutations
    // mutate_expr Lab2 → [BOT]: 1 result mutation
    // mutate_pc: 1 PC mutation
    case retCheckDropsRetVal    // check = LE LabPC (JOIN Lab2 Lab3)
    case retCheckDropsPC        // check = LE Lab1 (JOIN Lab2 Lab3)
    case retDropsResult         // result = BOT
    case retDropsPC             // result = JOIN(Lab2, Lab3), PC = BOT

    // MARK: - Nop: << TRUE, __, LabPC >>
    // result = None → mutate_pc None: 1 PC mutation (drop LabPC → BOT)
    case nopDropsPC             // PC = BOT

    // MARK: - MLab: << TRUE, Lab1, LabPC >>
    // Lab1=ptrLabel
    // mutate_expr Lab1 → [BOT]: 1 result mutation
    case mLabDropsResult        // result = BOT

    // MARK: - Alloc: << TRUE, JOIN Lab1 Lab2, LabPC >>
    // Lab1=sizeLabel, Lab2=labLabel
    // mutate_expr (JOIN Lab1 Lab2) → [Lab2, Lab1]: 2 result mutations
    case allocDropsLHS          // result = Lab2 (drops sizeLabel)
    case allocDropsRHS          // result = Lab1 (drops labLabel)

    // MARK: - PSetOff: << TRUE, JOIN Lab1 Lab2, LabPC >>
    // Lab1=ptrLabel, Lab2=offLabel
    // mutate_expr (JOIN Lab1 Lab2) → [Lab2, Lab1]: 2 result mutations
    case pSetOffDropsLHS        // result = Lab2 (drops ptrLabel)
    case pSetOffDropsRHS        // result = Lab1 (drops offLabel)

    // MARK: - PGetOff: << TRUE, Lab1, LabPC >>
    // Lab1=ptrLabel
    // mutate_expr Lab1 → [BOT]: 1 result mutation
    case pGetOffDropsResult     // result = BOT

    // MARK: - MSize: << TRUE, Lab2, JOIN LabPC Lab1 >>
    // Lab1=ptrLabel, Lab2=frameLabel
    // mutate_expr Lab2 → [BOT]: 1 result mutation
    // mutate_pc (Some Lab2) (JOIN LabPC Lab1): 1 PC mutation (Lab1 moved to result)
    case mSizeDropsResult       // result = BOT
    case mSizeDropsPtrFromPC    // result = JOIN(frame, ptr), PC = LabPC
}

extension IFCBug {
    /// Create a rule table with this bug injected.
    public var rules: RuleTable {
        var r = RuleTable.correct
        switch self {

        // MARK: Mov
        case .movDropsResult:
            r.movRule = { _, pc in (resultLabel: .low, newPCLabel: pc) }

        // MARK: BinOp
        case .binOpDropsLHS:
            r.binOpRule = { _, rhs, pc in (resultLabel: rhs, newPCLabel: pc) }
        case .binOpDropsRHS:
            r.binOpRule = { lhs, _, pc in (resultLabel: lhs, newPCLabel: pc) }

        // MARK: Load (Lab1=ptr, Lab2=frame, Lab3=memVal)
        case .loadDropsResult:
            r.loadRule = { ptr, frame, _, pc in
                (resultLabel: .low, newPCLabel: pc.join(ptr.join(frame)))
            }
        case .loadDropsPtrFromPC:
            r.loadRule = { ptr, frame, memVal, pc in
                (resultLabel: memVal.join(ptr), newPCLabel: pc.join(frame))
            }
        case .loadDropsFrameFromPC:
            r.loadRule = { ptr, frame, memVal, pc in
                (resultLabel: memVal.join(frame), newPCLabel: pc.join(ptr))
            }

        // MARK: Store (Lab1=ptr, Lab2=frame, Lab3=val)
        case .storeCheckDropsPtr:
            r.storeRule = { _, frame, val, pc in
                guard pc.flowsTo(frame) else { return nil }
                return (resultLabel: val, newPCLabel: pc)
            }
        case .storeCheckDropsPC:
            r.storeRule = { ptr, frame, val, pc in
                guard ptr.flowsTo(frame) else { return nil }
                return (resultLabel: val, newPCLabel: pc)
            }
        case .storeDropsResult:
            r.storeRule = { ptr, frame, _, pc in
                let check = ptr.join(pc)
                guard check.flowsTo(frame) else { return nil }
                return (resultLabel: .low, newPCLabel: pc)
            }

        // MARK: Write (Lab1=ptr, Lab2=frame, Lab3=val, Lab4=cell)
        case .writeCheckDropsPC:
            r.writeRule = { ptr, frame, val, cell, pc in
                let check = ptr.join(val)
                guard check.flowsTo(frame.join(cell)) else { return nil }
                return (resultLabel: cell, newPCLabel: pc)
            }
        case .writeCheckDropsPtr:
            r.writeRule = { _, frame, val, cell, pc in
                let check = pc.join(val)
                guard check.flowsTo(frame.join(cell)) else { return nil }
                return (resultLabel: cell, newPCLabel: pc)
            }
        case .writeCheckDropsValue:
            r.writeRule = { ptr, frame, _, cell, pc in
                let check = pc.join(ptr)
                guard check.flowsTo(frame.join(cell)) else { return nil }
                return (resultLabel: cell, newPCLabel: pc)
            }
        case .writeDropsResult:
            r.writeRule = { ptr, frame, val, cell, pc in
                let check = pc.join(ptr).join(val)
                guard check.flowsTo(frame.join(cell)) else { return nil }
                return (resultLabel: .low, newPCLabel: pc)
            }

        // MARK: Jump (Lab1=target)
        case .jumpDropsPC:
            r.jumpRule = { target, _ in (resultLabel: nil, newPCLabel: target) }
        case .jumpDropsTargetLabel:
            r.jumpRule = { _, pc in (resultLabel: nil, newPCLabel: pc) }

        // MARK: BNZ (Lab1=test)
        case .bnzDropsTestLabel:
            r.bnzRule = { _, pc in (resultLabel: nil, newPCLabel: pc) }
        case .bnzDropsPC:
            r.bnzRule = { test, _ in (resultLabel: nil, newPCLabel: test) }

        // MARK: BCall (Lab1=target, Lab2=retBound)
        case .callDropsRetBound:
            r.callRule = { target, _, pc in
                (resultLabel: pc, newPCLabel: target.join(pc))
            }
        case .callDropsPCFromResult:
            r.callRule = { target, retBound, pc in
                (resultLabel: retBound, newPCLabel: target.join(pc))
            }
        case .callDropsTargetFromPC:
            r.callRule = { target, retBound, pc in
                (resultLabel: target.join(retBound.join(pc)), newPCLabel: pc)
            }

        // MARK: BRet (Lab1=retVal, Lab2=savedBound, Lab3=savedPC)
        case .retCheckDropsRetVal:
            r.retRule = { _, savedBound, savedPC, pc in
                let target = savedBound.join(savedPC)
                guard pc.flowsTo(target) else { return nil }
                return (resultLabel: savedBound, newPCLabel: savedPC)
            }
        case .retCheckDropsPC:
            r.retRule = { retVal, savedBound, savedPC, _ in
                let target = savedBound.join(savedPC)
                guard retVal.flowsTo(target) else { return nil }
                return (resultLabel: savedBound, newPCLabel: savedPC)
            }
        case .retDropsResult:
            r.retRule = { retVal, savedBound, savedPC, pc in
                let check = retVal.join(pc)
                let target = savedBound.join(savedPC)
                guard check.flowsTo(target) else { return nil }
                return (resultLabel: .low, newPCLabel: savedPC)
            }
        case .retDropsPC:
            r.retRule = { retVal, savedBound, savedPC, pc in
                let check = retVal.join(pc)
                let target = savedBound.join(savedPC)
                guard check.flowsTo(target) else { return nil }
                return (resultLabel: savedBound.join(savedPC), newPCLabel: .low)
            }

        // MARK: Nop
        case .nopDropsPC:
            r.nopRule = { _ in (resultLabel: nil, newPCLabel: .low) }

        // MARK: MLab (Lab1=ptrLabel)
        case .mLabDropsResult:
            r.mLabRule = { _, pc in (resultLabel: .low, newPCLabel: pc) }

        // MARK: Alloc (Lab1=size, Lab2=lab)
        case .allocDropsLHS:
            r.allocRule = { _, lab, pc in (resultLabel: lab, newPCLabel: pc) }
        case .allocDropsRHS:
            r.allocRule = { size, _, pc in (resultLabel: size, newPCLabel: pc) }

        // MARK: PSetOff (Lab1=ptr, Lab2=off)
        case .pSetOffDropsLHS:
            r.pSetOffRule = { _, off, pc in (resultLabel: off, newPCLabel: pc) }
        case .pSetOffDropsRHS:
            r.pSetOffRule = { ptr, _, pc in (resultLabel: ptr, newPCLabel: pc) }

        // MARK: PGetOff (Lab1=ptr)
        case .pGetOffDropsResult:
            r.pGetOffRule = { _, pc in (resultLabel: .low, newPCLabel: pc) }

        // MARK: MSize (Lab1=ptr, Lab2=frame)
        case .mSizeDropsResult:
            r.mSizeRule = { _, _, pc in (resultLabel: .low, newPCLabel: pc) }
        case .mSizeDropsPtrFromPC:
            r.mSizeRule = { ptr, frame, pc in (resultLabel: frame.join(ptr), newPCLabel: pc) }
        }
        return r
    }
}
