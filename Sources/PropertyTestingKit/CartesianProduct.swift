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
