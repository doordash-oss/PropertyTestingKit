/*
 Plan
 With semi-random input, you must also define the expected output for arbitrary input.
 That's a lot of logic in tests, but you aren't really rewriting the underlying function.
 Because you only care about the boundaries. But the underlying function probably also
 encodes the boundaries.
 
 Lets see if we can make this work without the macro first.
 Create a list of common boundaries for types of input.
 */
import Foundation

// Note: Fuzz extensions for String, Int, Bool are now defined in Fuzzing/Fuzzable.swift
// as part of the Fuzzable protocol conformances.


func cartesianProduct<each T>(_ input: repeat [each T]) -> [(repeat each T)] {
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

@inlinable public func product<each Collection: Swift.Collection>(
    _ collection: repeat each Collection
) -> UnfoldSequence<
    (repeat (each Collection).Element),
    (collection: (repeat each Collection), index: (repeat (each Collection).Index))
> {
    var done = false
    for collection in repeat each collection {
        guard !collection.isEmpty else {
            done = true
            break
        }
    }
    
    return sequence(
        state: (
            collection: (repeat each collection),
            index: (repeat (each collection).startIndex)
        )
    ) { state in
        if done { return nil }
        
        defer {
            // Advance the index by incrementing the first digit.
            var carry = true
            
            state.index = (repeat {
                let collection = each state.collection
                var index = each state.index
                
                // Increment this digit if necessary.
                if carry {
                    collection.formIndex(after: &index)
                    carry = false
                }
                
                // Check for wraparound.
                if index < collection.endIndex {
                    // Still in range.
                    return index
                } else {
                    // We wrapped around; increment the next digit.
                    carry = true
                    return collection.startIndex
                }
            }())
            
            // If the last digit wrapped around, we're done.
            done = carry
        }
        
        // Return the current element.
        return (repeat (each state.collection)[each state.index])
    }
}
