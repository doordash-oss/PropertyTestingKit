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

//  Tests for sancov_cmp_should_drop() — the symbol classifier behind the
//  PTK_CMP_DROP_SYNTHESIZED comparison filter. It drops synthesized/stdlib
//  comparison sites (Swift.Array bounds checks, __derived_enum_equals, value
//  witnesses, outlined ops) while keeping user-module SUT-logic comparisons.
//  The mangled fixtures below are the actual hot comparison sites observed in
//  the STLC workload census (scheduler-lab Finding 41g).

import Testing
import SanCovHooks

@Suite("SanCov Comparison Drop Classifier")
struct SanCovCmpDropTests {

    // MARK: - KEEP: user-module SUT logic

    @Test("keeps SUT-logic functions")
    func keepsSutLogic() {
        // STLC.shift closure, STLC.subst, STLC.getTyp, STLC.pstep — the
        // comparisons the value-aware strategy actually needs.
        let keep = [
            "$s4STLC5shiftyAA4ExprOSi_ADtF2goL_yADSi_ADSitF",  // go #1 in STLC.shift
            "$s4STLC5substyAA4ExprOSi_A2DtF",                  // STLC.subst
            "$s4STLC6getTypyAA0C0OSgSayADG_AA4ExprOtF",        // STLC.getTyp
            "$s4STLC5pstepyAA4ExprOSgADF",                     // STLC.pstep
            "$s4STLC3TypO11descriptionSSvg",                   // STLC.Typ.description (user code)
        ]
        for sym in keep {
            #expect(sancov_cmp_should_drop(sym) == false, "should KEEP \(sym)")
        }
    }

    // MARK: - DROP: synthesized

    @Test("drops synthesized Equatable")
    func dropsDerivedEnumEquals() {
        #expect(sancov_cmp_should_drop("$s4STLC3TypO21__derived_enum_equalsySbAC_ACtFZ") == true)
    }

    @Test("drops value witnesses")
    func dropsValueWitness() {
        #expect(sancov_cmp_should_drop("$s4STLC4ExprOwst") == true)  // storeEnumTagSinglePayload
    }

    @Test("drops outlined ops")
    func dropsOutlined() {
        // outlined consume of STLC.Expr? / STLC.Typ? — caught via the shared
        // sancov_is_compiler_generated WO suffix check.
        #expect(sancov_cmp_should_drop("$s4STLC4ExprOSgWOe") == true)
        #expect(sancov_cmp_should_drop("$s4STLC3TypOSgWOe") == true)
    }

    // MARK: - DROP: stdlib (Swift module / standard substitutions)

    @Test("drops stdlib Array internals")
    func dropsStdlibArray() {
        let drop = [
            "$sSa5countSivg4STLC3TypO_Tg5",  // Swift.Array.count.getter
            "$sSa15_checkSubscript_20wasNativeTypeCheckeds16_DependenceTokenVSi_SbtF4STLC3TypO_Tg5",
            "$sSa15replaceSubrange_4withySnySiG_qd__nt7ElementQyd__RszSlRd__lF4STLC3TypO_s15CollectionOfOneVyAHGTg5",
            "$ss22_ContiguousArrayBufferV13_copyContents8subRange12initializingSpyxGSnySiG_AFtF4STLC3TypO_Tg5Tf4nng_n",
        ]
        for sym in drop {
            #expect(sancov_cmp_should_drop(sym) == true, "should DROP \(sym)")
        }
    }

    // MARK: - Robustness

    @Test("nil symbol is kept")
    func nilIsKept() {
        #expect(sancov_cmp_should_drop(nil) == false)
    }
}
