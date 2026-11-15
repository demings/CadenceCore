import Foundation
import Testing
@testable import TrainerProtocol

@Test func intensityChangesOnlyTargetsNotFTPOrTiming() throws {
    let workout = Workout(name: "Ride", description: "", intervals: [
        .init(duration: 60, startPower: 0.5, endPower: 0.5)
    ], warnings: [])
    var engine = try WorkoutPlayback(workout: workout, ftp: 200, range: PowerRange(minimum: 0, maximum: 2000, increment: 1))
    _ = engine.begin()
    _ = engine.acknowledged(opcode: 5, now: 1)
    _ = engine.acknowledged(opcode: 7, now: 1)
    _ = engine.service(now: 2)
    #expect(try engine.adjustIntensity(1.2, commandPending: false) == .target(120))
    #expect(engine.ftp == 200)
    #expect(engine.elapsed == 1)
    #expect(engine.state == .running)
    #expect(throws: WorkoutImportError.self) { try engine.adjustIntensity(1.6, commandPending: false) }
    #expect(throws: WorkoutImportError.self) { try engine.adjustIntensity(1, commandPending: true) }
    #expect(engine.intensity == 1.2)
}

@Test func wattBiasAppliesAfterIntensityAcrossRampsAndIntervalsWithoutChangingTimeOrFTP() throws {
    let workout = Workout(name: "Bias", description: "", intervals: [
        .init(duration: 2, startPower: 0.5, endPower: 1),
        .init(duration: 60, startPower: 0.75, endPower: 0.75)
    ], warnings: [])
    var engine = try WorkoutPlayback(workout: workout, ftp: 200,
        range: .init(minimum: 0, maximum: 2000, increment: 1))
    #expect(engine.begin() == .target(100))
    _ = engine.acknowledged(opcode: 5, now: 0)
    _ = engine.acknowledged(opcode: 7, now: 0)
    #expect(try engine.adjustIntensity(1.2, commandPending: false) == .target(120))
    #expect(try engine.adjustWattBias(10, commandPending: false) == .target(130))
    #expect(engine.service(now: 1) == .target(190))
    #expect(engine.service(now: 2) == nil)
    #expect(try engine.adjustWattBias(-10, commandPending: false) == .target(170))
    #expect(engine.elapsed == 2)
    #expect(engine.ftp == 200)
    #expect(engine.workout == workout)
    #expect(try engine.adjustWattBias(0, commandPending: false) == .target(180))
    #expect(engine.pause(now: 2) == .reducedLoadStop)
    engine.stopped()
    #expect(try engine.adjustWattBias(15, commandPending: false) == nil)
    #expect(engine.elapsed == 2)
    #expect(engine.begin() == .target(195))
    _ = engine.acknowledged(opcode: 5, now: 3)
    _ = engine.acknowledged(opcode: 7, now: 3)
    #expect(engine.finish(now: 3) == .reducedLoadStop)
}

@Test func wattBiasRejectsUnsafeFutureTargetsPendingCommandsAndNonRideStatesAtomically() throws {
    let workout = Workout(name: "Limits", description: "", intervals: [
        .init(duration: 10, startPower: 0.1, endPower: 0.1),
        .init(duration: 10, startPower: 0.5, endPower: 1)
    ], warnings: [])
    var engine = try WorkoutPlayback(workout: workout, ftp: 200,
        range: .init(minimum: 0, maximum: 210, increment: 1))
    #expect(throws: WorkoutImportError.self) { try engine.adjustWattBias(5, commandPending: false) }
    _ = engine.begin()
    _ = engine.acknowledged(opcode: 5, now: 0)
    _ = engine.acknowledged(opcode: 7, now: 0)
    #expect(try engine.adjustWattBias(10, commandPending: false) == .target(30))
    for bias in [11, -21, Int.max] {
        #expect(throws: WorkoutImportError.self) { try engine.adjustWattBias(bias, commandPending: false) }
        #expect(engine.wattBias == 10)
        #expect(engine.position?.targetWatts == 30)
    }
    #expect(throws: WorkoutImportError.self) { try engine.adjustWattBias(0, commandPending: true) }
    #expect(throws: WorkoutImportError.self) { try engine.adjustIntensity(1.1, commandPending: false) }
    #expect(engine.intensity == 1)
    engine.interrupt("Disconnected")
    #expect(throws: WorkoutImportError.self) { try engine.adjustWattBias(0, commandPending: false) }
}

@Test func wattBiasRespectsTrainerRoundingAndRecoveryDoesNotAutoResume() throws {
    let workout = Workout(name: "Steps", description: "",
        intervals: [.init(duration: 60, startPower: 0.5, endPower: 0.5)], warnings: [])
    var engine = try WorkoutPlayback(recovering: workout, ftp: 200,
        range: .init(minimum: 0, maximum: 2000, increment: 5), elapsed: 20,
        intensity: 1.1, wattBias: -6)
    #expect(engine.position?.targetWatts == 105)
    #expect(engine.state == .interrupted)
    #expect(engine.service(now: 999) == nil)
    #expect(engine.elapsed == 20)
    #expect(engine.begin() == .target(105))
    _ = engine.acknowledged(opcode: 5, now: 1000)
    _ = engine.acknowledged(opcode: 7, now: 1000)
    #expect(try engine.adjustWattBias(-5, commandPending: false) == nil)
    #expect(engine.wattBias == -5)
    #expect(throws: WorkoutImportError.self) {
        try WorkoutPlayback(recovering: workout, ftp: 200,
            range: .init(minimum: 0, maximum: 2000, increment: 5), elapsed: 20, wattBias: -101)
    }
    #expect(try WorkoutPlayback(workout: workout, ftp: 200,
        range: .init(minimum: 0, maximum: 2000, increment: 5)).wattBias == 0)
}

@Test func recoveryNeverStartsOrBridgesSimulationGapWithoutExplicitAction() throws {
    let workout = Workout(name: "Ride", description: "", intervals: [
        .init(duration: 60, startPower: 0.5, endPower: 0.5)
    ], warnings: [])
    var engine = try WorkoutPlayback(recovering: workout, ftp: 200,
        range: PowerRange(minimum: 0, maximum: 2000, increment: 1), elapsed: 20, intensity: 1.1)
    #expect(engine.state == .interrupted)
    #expect(engine.elapsed == 20)
    #expect(engine.service(now: 999) == nil)
    #expect(engine.begin() == .target(110))
    _ = engine.acknowledged(opcode: 5, now: 1000)
    _ = engine.acknowledged(opcode: 7, now: 1001)
    _ = engine.service(now: 1002)
    #expect(engine.elapsed == 21)
    var simulation = try RideSimulation(configuration: SimulationConfiguration(riderMass: 75), recoveredDistance: 123)
    try simulation.sample(watts: 100, uptime: 1000, activeTime: 20, date: Date())
    #expect(simulation.metrics.distance == 123)
}

@Test func recoveryRejectsScaledTargetsBelowTrainerMinimum() throws {
    let workout = Workout(name: "Minimum", description: "", intervals: [
        .init(duration: 60, startPower: 0.5, endPower: 0.5)
    ], warnings: [])
    #expect(throws: WorkoutImportError.self) {
        try WorkoutPlayback(recovering: workout, ftp: 200,
            range: PowerRange(minimum: 100, maximum: 2000, increment: 1), elapsed: 20, intensity: 0.5)
    }
}
    @Test func recoveryAtExactCompletionNeverRestartsTheLastInterval() throws {
        let workout = Workout(name: "Complete", description: "",
            intervals: [.init(duration: 60, startPower: 0.5, endPower: 0.5)], warnings: [])
        var engine = try WorkoutPlayback(recovering: workout, ftp: 200,
            range: .init(minimum: 0, maximum: 2000, increment: 1), elapsed: 60)
        #expect(engine.position == nil)
        #expect(engine.begin() == nil)
        #expect(engine.elapsed == 60)
        #expect(engine.finish() == .reducedLoadStop)
    }
