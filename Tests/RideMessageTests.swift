import Foundation
import Testing
@testable import TrainerProtocol

private func snapshot(sequence: Int = 1, state: String = "running", date: Date?) -> RideSnapshot {
    RideSnapshot(sequence: sequence, state: state, elapsed: 10, interval: 1, remaining: 20,
                 target: 100, power: 98, cadence: 85, telemetryDate: date, status: "Running")
}

@Test func rideMessagesRoundTripAndRejectStaleControls() throws {
    let now = Date()
    let id = UUID()
    let message = RideMessage(rideID: id, action: .pause, date: now)
    let decoded = try RideMessage.decode(JSONEncoder().encode(message), now: now)
    #expect(decoded.rideID == id)
    #expect(decoded.commandID == message.commandID)
    #expect(decoded.action == .pause)
    let stale = RideMessage(rideID: id, action: .resume, date: now.addingTimeInterval(-10.001))
    #expect(throws: RideLinkError.self) {
        try RideMessage.decode(JSONEncoder().encode(stale), now: now, allowDelayedReceipt: true)
    }
    let future = RideMessage(rideID: id, action: .finish, date: now.addingTimeInterval(5.001))
    #expect(throws: RideLinkError.self) {
        try RideMessage.decode(JSONEncoder().encode(future), now: now)
    }
}

@Test func delayedSaveReceiptIsNotTreatedAsLiveControl() throws {
    let now = Date()
    let receipt = RideMessage(rideID: UUID(), action: .saved, date: now.addingTimeInterval(-86400),
                              detail: "Saved to Health")
    let data = try JSONEncoder().encode(receipt)
    #expect(throws: RideLinkError.self) { try RideMessage.decode(data, now: now) }
    #expect(try RideMessage.decode(data, now: now, allowDelayedReceipt: true).action == .saved)
}

@Test func commandsAreDeduplicatedAndBoundToOneRide() {
    let ride = UUID()
    var gate = RideCommandGate(rideID: ride)
    let pause = RideMessage(rideID: ride, action: .pause)
    let accepted = gate.accept(pause)
    #expect(accepted)
    let retry = RideMessage(rideID: ride, action: .pause, date: Date(), commandID: pause.commandID)
    let duplicate = gate.accept(retry)
    let wrongRide = gate.accept(RideMessage(rideID: UUID(), action: .finish))
    let resume = gate.accept(RideMessage(rideID: ride, action: .resume))
    #expect(!duplicate)
    #expect(!wrongRide)
    #expect(resume)
}

@Test func validatesMessageShapesAndBoundedStaging() throws {
    let now = Date()
    #expect(!RideDescriptor(id: UUID(), name: "", duration: 60, ftp: 200).isValid)
    #expect(!RideDescriptor(id: UUID(), name: "Ride", duration: .nan, ftp: 200).isValid)
    #expect(!RideDescriptor(id: UUID(), name: "Ride", duration: 21601, ftp: 200).isValid)
    #expect(!RideDescriptor(id: UUID(), name: "Ride", duration: 60, ftp: 0).isValid)
    #expect(RideDescriptor(id: UUID(), name: "Ride", duration: 21600, ftp: 2000).isValid)
    for message in [
        RideMessage(rideID: UUID(), action: .snapshot, date: now),
        RideMessage(rideID: nil, action: .heartRate, date: now),
        RideMessage(rideID: nil, action: .heartRate, date: now, bpm: 0),
        RideMessage(rideID: nil, action: .ready, date: now),
        RideMessage(rideID: UUID(), action: .snapshot, date: now,
                    snapshot: snapshot(state: "invented", date: now))
    ] {
        #expect(throws: RideLinkError.self) {
            try RideMessage.decode(JSONEncoder().encode(message), now: now)
        }
    }
}

@Test func trainerRecordingWindowsNeverBridgePauseGapsOrDuplicatePackets() {
    let start = Date()
    var windows = TrainerSampleWindow()
    #expect(windows.take(snapshot(date: start), now: start, collectionStart: start) == nil)
    let second = start.addingTimeInterval(1)
    #expect(windows.take(snapshot(date: second), now: second, collectionStart: start)?.duration == 1)
    #expect(windows.take(snapshot(date: second), now: second, collectionStart: start) == nil)
    #expect(windows.take(snapshot(state: "paused", date: second), now: second, collectionStart: start) == nil)
    let resumed = start.addingTimeInterval(50)
    #expect(windows.take(snapshot(date: resumed), now: resumed, collectionStart: start) == nil)
    let next = resumed.addingTimeInterval(3)
    #expect(windows.take(snapshot(date: next), now: next, collectionStart: start)?.duration == 3)
    let gap = next.addingTimeInterval(3.001)
    #expect(windows.take(snapshot(date: gap), now: gap, collectionStart: start) == nil)
    #expect(windows.take(snapshot(date: gap), now: gap.addingTimeInterval(4), collectionStart: start) == nil)
}

@Test func trainerRecordingRejectsSamplesBeforeCollectionAndFromFuture() {
    let start = Date()
    var windows = TrainerSampleWindow()
    #expect(windows.take(snapshot(date: start.addingTimeInterval(-1)), now: start, collectionStart: start) == nil)
    #expect(windows.take(snapshot(date: start.addingTimeInterval(1.001)), now: start, collectionStart: start) == nil)
    #expect(windows.take(snapshot(date: nil), now: start, collectionStart: start) == nil)
}
