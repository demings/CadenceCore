import Foundation

public enum ProtocolError: Error, Equatable, LocalizedError {
    case truncatedPacket
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .truncatedPacket: "The trainer returned an incomplete Bluetooth packet."
        case .invalidResponse: "The trainer returned an invalid control response."
        }
    }
}

public struct IndoorBikeData: Equatable, Sendable {
    public let cadence: Double?
    public let power: Int?

    public static func decode(_ data: Data) throws -> Self {
        var reader = ByteReader(data)
        let flags = try reader.uint16()
        if flags & 1 == 0 { _ = try reader.uint16() }
        if flags & (1 << 1) != 0 { _ = try reader.uint16() }
        let cadence = flags & (1 << 2) != 0 ? Double(try reader.uint16()) / 2 : nil
        if flags & (1 << 3) != 0 { _ = try reader.uint16() }
        if flags & (1 << 4) != 0 { try reader.skip(3) }
        if flags & (1 << 5) != 0 { _ = try reader.uint16() }
        let power = flags & (1 << 6) != 0 ? Int(Int16(bitPattern: try reader.uint16())) : nil
        if flags & (1 << 7) != 0 { _ = try reader.uint16() }
        if flags & (1 << 8) != 0 { try reader.skip(5) }
        if flags & (1 << 9) != 0 { try reader.skip(1) }
        if flags & (1 << 10) != 0 { try reader.skip(1) }
        if flags & (1 << 11) != 0 { try reader.skip(2) }
        if flags & (1 << 12) != 0 { try reader.skip(2) }
        return Self(cadence: cadence, power: power)
    }
}

public struct PowerRange: Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int
    public let increment: Int

    public static func decode(_ data: Data) throws -> Self {
        var reader = ByteReader(data)
        let minimum = Int(Int16(bitPattern: try reader.uint16()))
        let maximum = Int(Int16(bitPattern: try reader.uint16()))
        let increment = Int(try reader.uint16())
        guard minimum <= maximum, increment > 0 else { throw ProtocolError.invalidResponse }
        return Self(minimum: minimum, maximum: maximum, increment: increment)
    }

    public func contains(_ watts: Int) -> Bool {
        watts >= minimum && watts <= maximum && (watts - minimum).isMultiple(of: increment)
    }
}

public enum FTMS {
    public static func supportsTargetPower(_ data: Data) throws -> Bool {
        var reader = ByteReader(data)
        try reader.skip(4)
        let low = try reader.uint16()
        _ = try reader.uint16()
        return low & (1 << 3) != 0
    }

    public static func response(_ data: Data) throws -> (opcode: UInt8, result: UInt8) {
        guard data.count == 3, data[data.startIndex] == 0x80 else { throw ProtocolError.invalidResponse }
        let bytes = Array(data)
        return (bytes[1], bytes[2])
    }

    public static func targetPower(_ watts: Int16) -> Data {
        let value = UInt16(bitPattern: watts)
        return Data([0x05, UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func skip(_ count: Int) throws {
        guard count <= bytes.count - offset else { throw ProtocolError.truncatedPacket }
        offset += count
    }

    mutating func uint16() throws -> UInt16 {
        guard bytes.count - offset >= 2 else { throw ProtocolError.truncatedPacket }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}
