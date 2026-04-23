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

//  Built-in string mutation strategies for fuzz testing.
//

// MARK: - String Mutator Static Properties

extension Mutator where Value == String {
    public static let phoneNumbers = phoneNumberMutator
    public static let emails = emailMutator
    public static let urls = urlMutator
    public static let sql = sqlInjectionMutator
    public static let xss = xssMutator
    public static let unicode = unicodeMutator
    public static let whitespace = whitespaceMutator
    public static let empty = emptyStringMutator
    public static let boundaries = stringBoundaryMutator
}

extension String {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ mutators: Mutator<String>...) -> Mutator<String> {
        Mutator.compose(mutators)
    }
}
