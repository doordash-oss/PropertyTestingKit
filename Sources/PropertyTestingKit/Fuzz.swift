import Foundation

//protocol Fuzzable {
//    func fuzz() -> any Sequence<Self>
//}

// Property testing requires a means to fuzz, and a means to assert output for qualities of the input
//extension Int: Fuzzable {
//    /// Produces a random sequence of Ints in range lowerBound...upperBound
//    func fuzz(lowerBound: Int = Int.min, upperBound: Int = Int.max, count: Int = 10) -> any Sequence<Int> {
//        AnySequence {
//            AnyIterator {
//                Int.random(in: lowerBound...upperBound)
//            }
//        }
//    }
//}
//
//extension Float: Fuzzable {
//    /// Produces a random sequence of Ints in range lowerBound...upperBound
//    func fuzz(lowerBound: Float = -Float.greatestFiniteMagnitude, upperBound: Float = Float.greatestFiniteMagnitude, count: Int = 10) -> any Sequence<Float> {
//        AnySequence {
//            AnyIterator {
//                Float.random(in: lowerBound...upperBound)
//            }
//        }
//    }
//}
//
//extension Double: Fuzzable {
//    func fuzz(lowerBound: Double = -Double.greatestFiniteMagnitude, upperBound: Double = Double.greatestFiniteMagnitude, count: Int = 10) -> any Sequence<Double> {
//        AnySequence {
//            AnyIterator {
//                .random(in: lowerBound...upperBound)
//            }
//        }
//    }
//}
//
//extension String: Fuzzable {
//    func fuzz(count: Int = 10) -> any Sequence<String> {
//        AnySequence {
//            AnyIterator {
//                String((0..<Int.random(in: 1...count)).self.map { _ in Character(UnicodeScalar(Int.random(in: 97...122))!) })
//            }
//        }
//    }
//}

protocol Fuzzable: Comparable {
    static var upperBound: Self { get }
    static var lowerBound: Self { get }
    static func random(in: Range<Self>) -> Self
    static func random(in: ClosedRange<Self>) -> Self
    static var commonEdgeCases: [Self] { get }
}

//extension Int: Fuzzable {
//    var upperBound: Int { Int.max }
//    var lowerBound: Int { Int.min }
//    func random(in range: Range<Int>) -> Int { .random(in: range) }
//}
//
//extension Float: Fuzzable {
//    var upperBound: Float { .greatestFiniteMagnitude }
//    var lowerBound: Float { -.greatestFiniteMagnitude }
//    func random(in range: Range<Float>) -> Float { .random(in: range) }
//}

extension Fuzzable where Self: FloatingPoint {
    static var upperBound: Self { .greatestFiniteMagnitude }
    static var lowerBound: Self { -.greatestFiniteMagnitude }
    static var floatingPointEdgeCases: [Self] {[
        .zero.advanced(by: 1),
        .zero.advanced(by: -1),
        -.zero,
        .zero,
        .infinity,
        -.infinity,
        .nan,
        .signalingNaN,
        .greatestFiniteMagnitude,
        -.greatestFiniteMagnitude
    ]}
}

extension Float: Fuzzable {
    static let commonEdgeCases: [Self] = floatingPointEdgeCases
}

extension Double: Fuzzable {
    static let commonEdgeCases: [Self] = floatingPointEdgeCases
}

extension Fuzzable where Self: FixedWidthInteger {
    static var upperBound: Self { .max }
    static var lowerBound: Self { .min }
}

struct FuzzSequence<Element: Fuzzable>: Sequence {
    typealias Iterator = AnyIterator<Element>
    let config: FuzzConfig<Element>
    
    func makeIterator() -> Iterator {
        AnyIterator {
            Element.random(in: config.lowerBound...config.upperBound)
        }
    }
}

struct FuzzConfig<Element: Fuzzable> {
    var upperBound: Element
    var lowerBound: Element
    
    init(upperBound: Element = .upperBound, lowerBound: Element = .lowerBound) {
        self.upperBound = upperBound
        self.lowerBound = lowerBound
    }
}

//func propertyTest<each T: Fuzzable>(_ configs: repeat FuzzConfig<each T>, closure: ((repeat each T)) async throws -> Void) async throws {
//    for something in zip(repeat FuzzSequence(config: each configs)) {
//        try await closure((something))
//    }
//}
