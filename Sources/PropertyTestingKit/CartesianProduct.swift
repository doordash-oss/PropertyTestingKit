import Foundation

public func cartesianProduct<each T>(_ input: (repeat [each T])) -> [(repeat each T)] {
    for array in repeat each input {
        guard !array.isEmpty else {
            return []
        }
    }

    var size = 1

    func makeRepeated<A>(_ array: [A]) -> RepeatEachElementSequence<[A]> {
        defer {
            size *= array.count
        }
        return RepeatEachElementSequence(base: array, count: size)
    }

    var iters = (repeat makeRepeated(each input).makeIterator())

    func nonMutatingNext<I: IteratorProtocol>(_ iter: I) -> (element: I.Element?, copy: I) {
        var copy = iter
        return (copy.next(), copy)
    }

    let res = (0..<size).map { _ in
        let x = (repeat nonMutatingNext(each iters))
        iters = (repeat (each x).copy)
        return (repeat (each x).element!)
    }

    return res
}

public func cartesianProduct<each T>(_ input: repeat [each T]) -> [(repeat each T)] {
    cartesianProduct((repeat each input))
}

struct RepeatEachElementSequence<Base: Sequence>: Sequence {
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
    
    init(base: Base, count: Int) {
        self.base = base
        self.count = count
    }
    
    func makeIterator() -> Iterator {
        Iterator(base: base, count: count)
    }
}
