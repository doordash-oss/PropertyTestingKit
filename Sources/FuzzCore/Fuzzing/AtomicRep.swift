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

//  Disambiguating alias for swift-atomics' per-type atomic storage.
//
//  swift-atomics gives each `AtomicValue` an `AtomicRepresentation` associated
//  type (the flat storage our lock-free accumulators allocate buffers of). Newer
//  Swift toolchains ALSO conform the same integer types to the standard library's
//  `AtomicRepresentable` (built-in atomics / `Synchronization`), which has its own
//  member `AtomicRepresentation`. With both visible, the bare
//  `UInt64.AtomicRepresentation` is ambiguous and the build breaks after an
//  Xcode/SDK update — even though neither our code nor the swift-atomics pin
//  changed. Funnelling the lookup through a context constrained to swift-atomics'
//  `AtomicValue` resolves it to that package's storage type, unambiguously.

import Atomics

/// swift-atomics' atomic storage for `T` (e.g. `AtomicRep<UInt64>` ==
/// `UInt64.AtomicRepresentation` from the `Atomics` package). Use this instead of
/// the bare `T.AtomicRepresentation`, which collides with the stdlib's
/// `AtomicRepresentable.AtomicRepresentation` on newer toolchains.
public typealias AtomicRep<T: AtomicValue> = T.AtomicRepresentation
