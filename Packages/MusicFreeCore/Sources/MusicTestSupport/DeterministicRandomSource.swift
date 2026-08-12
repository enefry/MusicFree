import Foundation

/// A small deterministic SplitMix64 source suitable for reproducible queue
/// and shuffle tests. It is a value type, so each test task can own an
/// independent mutable sequence without shared state.
public struct DeterministicRandomSource: Sendable {
    public let seed: UInt64
    private var state: UInt64

    public init(seed: UInt64 = 0) {
        self.seed = seed
        state = seed
    }

    public mutating func reset() {
        state = seed
    }

    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    public mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0, "upperBound must be positive")
        return Int(nextUInt64() % UInt64(upperBound))
    }

    public mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            let other = nextInt(upperBound: index + 1)
            values.swapAt(index, other)
        }
    }

    public mutating func shuffled<T>(_ values: [T]) -> [T] {
        var result = values
        shuffle(&result)
        return result
    }

    public func sequence(count: Int) -> [UInt64] {
        precondition(count >= 0, "sequence count cannot be negative")
        var copy = self
        return (0..<count).map { _ in copy.nextUInt64() }
    }

    public static func shuffled<T>(_ values: [T], seed: UInt64) -> [T] {
        var source = Self(seed: seed)
        return source.shuffled(values)
    }
}

/// Produces stable IDs without using wall-clock UUID randomness.
public struct SequentialIDGenerator: Sendable {
    private var nextValue: UInt64

    public init(start: UInt64 = 0) {
        nextValue = start
    }

    public mutating func nextUUID() -> UUID {
        precondition(nextValue <= 0xFFFF_FFFF_FFFF, "SequentialIDGenerator exhausted")
        let value = String(nextValue, radix: 16, uppercase: false)
        nextValue += 1
        let suffix = String(repeating: "0", count: 12 - value.count) + value
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    public mutating func nextID(prefix: String = "fixture") -> String {
        let value = nextValue
        nextValue += 1
        return "\(prefix)-\(value)"
    }
}
