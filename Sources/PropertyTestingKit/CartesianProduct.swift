import Foundation

@inlinable
public func cartesianProduct<each T>(_ input: repeat [each T]) -> [(repeat each T)] {
    cartesianProduct((repeat each input))
}

@inlinable
public func cartesianProduct<each T>(_ input: (repeat [each T])) -> [(repeat each T)] {
    // Check for empty arrays
    for array in repeat each input {
        guard !array.isEmpty else {
            return []
        }
    }

    // First pass: collect array counts
    var counts: [Int] = []
    func recordCount<A>(_ array: [A]) {
        counts.append(array.count)
    }
    _ = (repeat recordCount(each input))

    // Compute strides from right to left
    // stride[i] = product of counts[i+1..<n]
    var strides: [Int] = []
    var stride = 1
    for i in (0..<counts.count).reversed() {
        strides.insert(stride, at: 0)
        stride *= counts[i]
    }
    let size = stride

    // Build result using index calculation (no iterator state)
    var strideIndex = 0
    return (0..<size).map { i in
        strideIndex = 0
        func getElement<A>(_ array: [A]) -> A {
            let idx = (i / strides[strideIndex]) % array.count
            strideIndex += 1
            return array[idx]
        }
        return (repeat getElement(each input))
    }
}

//@inlinable
//public func cartesianProduct<each T>(_ input: (repeat [each T])) -> [(repeat each T)] {
//    for array in repeat each input {
//        guard !array.isEmpty else {
//            return []
//        }
//    }
//
//    var size = 1
//
//    func makeRepeated<A>(_ array: [A]) -> RepeatEachElementSequence<[A]> {
//        defer {
//            size *= array.count
//        }
//        return RepeatEachElementSequence(base: array, count: size)
//    }
//
//    var iters = (repeat makeRepeated(each input).makeIterator())
//
//    func nonMutatingNext<I: IteratorProtocol>(_ iter: I) -> (element: I.Element?, copy: I) {
//        var copy = iter
//        return (copy.next(), copy)
//    }
//
//    let res = (0..<size).map { _ in
//        let x = (repeat nonMutatingNext(each iters))
//        iters = (repeat (each x).copy)
//        return (repeat (each x).element!)
//    }
//
//    return res
//}

@usableFromInline
struct RepeatEachElementSequence<Base: Sequence>: Sequence {
    @usableFromInline
    struct Iterator: IteratorProtocol {
        var base: Base
        var count: Int
        private var baseIterator: Base.Iterator
        private var i = 0
        private var currentElement: Base.Element?
        
        init(base: Base, count: Int) {
            self.base = base
            self.count = count
            baseIterator = base.makeIterator()
        }

        @usableFromInline
        mutating func next() -> Base.Element? {
            if i % count == 0 {
                currentElement = baseIterator.next()
            }
            if currentElement == nil {
                baseIterator = base.makeIterator()
                currentElement = baseIterator.next()
            }
            i += 1
            return currentElement
        }
    }
    
    var base: Base
    var count: Int

    @usableFromInline
    init(base: Base, count: Int) {
        self.base = base
        self.count = count
    }

    @usableFromInline
    func makeIterator() -> Iterator {
        Iterator(base: base, count: count)
    }
}
