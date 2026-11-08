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
