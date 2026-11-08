import Foundation
import Testing
@testable import TrainerProtocol

private func playback() throws -> WorkoutPlayback {
    try WorkoutPlayback(
        workout: Workout(name: "Test", description: "", intervals: [
            .init(duration: 2, startPower: 0.4, endPower: 0.4),
            .init(duration: 3, startPower: 0.5, endPower: 0.8, cadence: 90)
        ], warnings: []),
        ftp: 200, range: PowerRange.decode(Data([0, 0, 0xD0, 0x07, 1, 0]))
    )
}

@Test func playbackWaitsForTargetAndStartAcknowledgment() throws {
    var engine = try playback()
    #expect(engine.begin() == .target(80))
    #expect(engine.service(now: 10) == nil)
    #expect(engine.elapsed == 0)
    #expect(engine.acknowledged(opcode: 0, now: 10) == nil)
    #expect(engine.state == .settingTarget)
    #expect(engine.acknowledged(opcode: 5, now: 11) == .start)
    #expect(engine.state == .starting)
    #expect(engine.acknowledged(opcode: 7, now: 12) == nil)
    #expect(engine.state == .running)
    #expect(engine.service(now: 13) == nil)
    #expect(engine.elapsed == 1)
    #expect(engine.service(now: 14) == .target(100))
    #expect(engine.position?.index == 1)
    #expect(engine.position?.cadence == 90)
    #expect(engine.service(now: 15.5) == .target(130))
    #expect(engine.service(now: 17) == .reducedLoadStop)
    #expect(engine.state == .finishing)
    engine.stopped()
    #expect(engine.state == .completed)
}

@Test func pauseAndResumeExcludePausedAndHandshakeTime() throws {
    var engine = try playback()
    _ = engine.begin()
    _ = engine.acknowledged(opcode: 5, now: 0)
    _ = engine.acknowledged(opcode: 7, now: 0)
    #expect(engine.pause(now: 1) == .reducedLoadStop)
    #expect(engine.state == .pausing)
    #expect(engine.begin() == nil)
    engine.stopped()
    #expect(engine.state == .paused)
    #expect(engine.elapsed == 1)
    #expect(engine.begin() == .target(80))
    _ = engine.acknowledged(opcode: 5, now: 100)
    _ = engine.acknowledged(opcode: 7, now: 101)
    #expect(engine.service(now: 102) == .target(100))
    #expect(engine.elapsed == 2)
}

@Test func gapsFreezeInsteadOfSkippingIntervals() throws {
    var engine = try playback()
    _ = engine.begin()
    _ = engine.acknowledged(opcode: 5, now: 0)
    _ = engine.acknowledged(opcode: 7, now: 0)
    _ = engine.service(now: 1)
    #expect(engine.service(now: 20) == .reducedLoadStop)
    #expect(engine.state == .interrupted)
    #expect(engine.elapsed == 1)
    #expect(engine.error != nil)
    engine.stopped()
    #expect(engine.state == .interrupted)
    #expect(engine.begin() == .target(80))
}

@Test func finishAndFailureNeverClaimUnacknowledgedCompletion() throws {
    var engine = try playback()
    _ = engine.begin()
    #expect(engine.finish() == .reducedLoadStop)
    #expect(engine.state == .finishing)
    engine.interrupt("Stop failed")
    engine.stopped()
    #expect(engine.state == .interrupted)
    #expect(engine.error == "Stop failed")
}

@Test func playbackValidatesPersistedWorkoutsAndTrainerRange() throws {
    let range = try PowerRange.decode(Data([0, 0, 100, 0, 5, 0]))
    #expect(throws: WorkoutImportError.self) {
        try WorkoutPlayback(workout: .sample, ftp: .nan, range: range)
    }
    #expect(throws: WorkoutImportError.self) {
        try WorkoutPlayback(workout: .sample, ftp: 1000, range: range)
    }
    let workout = Workout(name: "Quantize", description: "", intervals: [
        .init(duration: 2, startPower: 0.413, endPower: 0.413)
    ], warnings: [])
    #expect(try WorkoutPlayback(workout: workout, ftp: 100, range: range).position?.targetWatts == 40)
}

@Test func pendingTargetsDoNotBlockTimingOrLoseLatestTarget() throws {
    var engine = try playback()
    _ = engine.begin()
    _ = engine.acknowledged(opcode: 5, now: 0)
    _ = engine.acknowledged(opcode: 7, now: 0)
    #expect(engine.service(now: 2) == .target(100))
    #expect(engine.service(now: 3, commandPending: true) == nil)
    #expect(engine.elapsed == 3)
    #expect(engine.service(now: 4) == .target(140))
    #expect(engine.service(now: 5, commandPending: true) == .reducedLoadStop)
    #expect(engine.state == .finishing)
}

@Test func finishDuringStartupWaitsForPendingThenZeroBeforeStop() throws {
    var engine = try playback()
    var stop = ReducedLoadStop()
    _ = engine.begin()
    #expect(engine.finish() == .reducedLoadStop)
    #expect(stop.begin(commandPending: true) == nil)
    #expect(engine.acknowledged(opcode: 5, now: 1) == nil)
    #expect(stop.commandAcknowledged() == .zeroWatts)
    #expect(engine.state == .finishing)
    #expect(stop.commandAcknowledged() == .stop)
    #expect(engine.state != .completed)
    #expect(stop.commandAcknowledged() == nil)
    engine.stopped()
    #expect(engine.state == .completed)
}

@Test func quantizationNeverExceedsSupportedIncrement() throws {
    let range = try PowerRange.decode(Data([0, 0, 100, 0, 6, 0]))
    let workout = Workout(name: "Quantize maximum", description: "", intervals: [
        .init(duration: 2, startPower: 0.99, endPower: 0.99)
    ], warnings: [])
    let engine = try WorkoutPlayback(workout: workout, ftp: 100, range: range)
    #expect(engine.position?.targetWatts == 96)
    #expect(range.contains(try #require(engine.position).targetWatts))
}

@Test func rejectsNonfiniteOrCorruptedStoredIntervals() throws {
    let range = try PowerRange.decode(Data([0, 0, 0xD0, 0x07, 1, 0]))
    for interval in [
        WorkoutInterval(duration: .nan, startPower: 0.5, endPower: 0.5),
        WorkoutInterval(duration: 0, startPower: 0.5, endPower: 0.5),
        WorkoutInterval(duration: 1, startPower: .infinity, endPower: 0.5),
        WorkoutInterval(duration: 1, startPower: 0.5, endPower: 0.5, cadence: -1)
    ] {
        let workout = Workout(name: "Invalid", description: "", intervals: [interval], warnings: [])
        #expect(throws: WorkoutImportError.self) {
            try WorkoutPlayback(workout: workout, ftp: 200, range: range)
        }
    }

}

@Test func timingGapThresholdIsExactlyThreeSeconds() throws {
    var engine = try playback()
    _ = engine.begin()
    _ = engine.acknowledged(opcode: 5, now: 0)
    _ = engine.acknowledged(opcode: 7, now: 0)
    _ = engine.service(now: 3)
    #expect(engine.state == .running)
    #expect(engine.elapsed == 3)
    #expect(engine.service(now: 6.001) == .reducedLoadStop)
    #expect(engine.state == .interrupted)
    #expect(engine.elapsed == 3)
}

@Test func manualFinishCapturesActiveTimeWithoutWaitingForTelemetry() throws {
    var engine = try playback()
    _ = engine.begin()
    _ = engine.acknowledged(opcode: 5, now: 0)
    _ = engine.acknowledged(opcode: 7, now: 0)
    _ = engine.service(now: 1)
    #expect(engine.finish(now: 1.75) == .reducedLoadStop)
    #expect(engine.elapsed == 1.75)
    #expect(engine.finish(now: 2) == nil)
    #expect(engine.elapsed == 1.75)
    engine.stopped()
    #expect(engine.state == .completed)
}
