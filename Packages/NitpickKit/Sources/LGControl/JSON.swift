import Foundation

/// A minimal JSON value for SSAP frames. Numbers are `Double`; integral values encode without a fraction
/// (`3072`, not `3072.0`), which the TV's parser needs for `dataCount`, `id` and similar fields.
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// A number, or a string holding a number: webOS 24/25 report most settings as strings (`"34"`), webOS 26 as numbers.
    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// `doubleValue` when it is integral.
    public var intValue: Int? {
        guard let d = doubleValue, d.isFinite, d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string("true"): return true
        case .string("false"): return false
        default: return nil
        }
    }

    public var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Equality that ignores the TV's string-vs-number encoding (`"40" == 40`), recursively.
    public func looselyEquals(_ other: JSON) -> Bool {
        switch (self, other) {
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.looselyEquals($1) }
        case (.object(let a), .object(let b)):
            return a.count == b.count && a.allSatisfy { k, v in b[k].map(v.looselyEquals) ?? false }
        default:
            if let x = doubleValue, let y = other.doubleValue { return x == y }
            if let x = boolValue, let y = other.boolValue { return x == y }
            return self == other
        }
    }

    /// UTF-8 JSON text with sorted keys and unescaped slashes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
    public static func decode(_ text: String) throws -> JSON { try decode(Data(text.utf8)) }
}

extension JSON: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
