import Foundation
import Testing
@testable import TrainerProtocol

@Test func decodesCadenceAndSignedPower() throws {
    let packet = Data([0x44, 0, 0xE8, 0x03, 180, 0, 250, 0])
    let result = try IndoorBikeData.decode(packet)
    #expect(result.cadence == 90)
    #expect(result.power == 250)
    #expect(try IndoorBikeData.decode(Data([0x41, 0, 0xFF, 0xFF])).power == -1)
}

@Test func skipsOptionalFieldsAndRejectsTruncation() throws {
    let packet = Data([0x7F, 0, 1, 0, 160, 0, 1, 0, 1, 2, 3, 1, 0, 100, 0])
    #expect(try IndoorBikeData.decode(packet).power == 100)
    for count in 0..<packet.count {
        #expect(throws: ProtocolError.self) { try IndoorBikeData.decode(packet.prefix(count)) }
    }
    #expect(try IndoorBikeData.decode(Data([1, 0])).cadence == nil)
}

@Test func validatesControlPackets() throws {
    #expect(FTMS.targetPower(250) == Data([5, 250, 0]))
    #expect(FTMS.targetPower(300) == Data([5, 44, 1]))
    #expect(try FTMS.response(Data([0x80, 5, 1])).opcode == 5)
    #expect(throws: ProtocolError.self) { try FTMS.response(Data([5, 1])) }
    #expect(throws: ProtocolError.self) { try FTMS.response(Data([0x80, 5, 1, 0])) }
    #expect(try FTMS.supportsTargetPower(Data([0, 0, 0, 0, 8, 0, 0, 0])))
    #expect(try !FTMS.supportsTargetPower(Data(repeating: 0, count: 8)))
}

@Test func validatesSupportedPowerRange() throws {
    let range = try PowerRange.decode(Data([0, 0, 0x08, 0x07, 5, 0]))
    #expect(range.contains(100))
    #expect(!range.contains(101))
    #expect(!range.contains(1805))
    #expect(!range.contains(-5))
    #expect(throws: ProtocolError.self) { try PowerRange.decode(Data([0, 0, 10, 0, 0, 0])) }
}
