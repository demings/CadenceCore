import Foundation
import Testing
@testable import TrainerProtocol

@Test func solvesFlatRoadPowerBalanceToNumericalTolerance() throws {
    let model = SimulationConfiguration(riderMass: 75)
    for watts in [1.0, 30, 100, 200, 400, 2000, 32767] {
        let speed = try model.speed(watts: watts)
        let modeled = (model.riderMass + model.bikeMass) * 9.80665 * model.rollingResistance * speed +
            0.5 * model.airDensity * model.dragArea * speed * speed * speed
        #expect(abs(modeled - watts * model.efficiency) < 0.000001)
    }
    let speed = try model.speed(watts: 200) * 3.6
    #expect(speed > 30 && speed < 35)
    #expect(try model.speed(watts: 0) == 0)
    #expect(try model.speed(watts: -10) == 0)
}

@Test func simulationSpeedRespondsToMassDragAndMeasuredPower() throws {
    let model = SimulationConfiguration(riderMass: 75)
    let speed = try model.speed(watts: 200)
    #expect(try model.speed(watts: 100) < speed)
    #expect(try SimulationConfiguration(riderMass: 100).speed(watts: 200) < speed)
    #expect(try SimulationConfiguration(riderMass: 75, dragArea: 0.5).speed(watts: 200) < speed)
    #expect(try SimulationConfiguration(riderMass: 75, efficiency: 0.9).speed(watts: 200) < speed)
    let extreme = SimulationConfiguration(riderMass: 20, bikeMass: 1, dragArea: 0.1,
        rollingResistance: 0.001, airDensity: 0.5, efficiency: 1)
    let highSpeed = try extreme.speed(watts: 32767)
    #expect(highSpeed > 100 && highSpeed < 200)
}

@Test func rejectsInvalidSimulationSetupAndPower() throws {
    let model = SimulationConfiguration(riderMass: 75)
    for invalid in [
        SimulationConfiguration(riderMass: .nan),
        SimulationConfiguration(riderMass: 19.99),
        SimulationConfiguration(riderMass: 301),
        SimulationConfiguration(riderMass: 75, bikeMass: 0),
        SimulationConfiguration(riderMass: 75, dragArea: 0),
        SimulationConfiguration(riderMass: 75, rollingResistance: .infinity),
        SimulationConfiguration(riderMass: 75, airDensity: 0),
        SimulationConfiguration(riderMass: 75, efficiency: 0),
        SimulationConfiguration(riderMass: 75, efficiency: 1.01)
    ] {
        #expect(!invalid.isValid)
        #expect(throws: SimulationError.self) { try RideSimulation(configuration: invalid) }
    }
    #expect(throws: SimulationError.self) { try model.speed(watts: .nan) }
    #expect(throws: SimulationError.self) { try model.speed(watts: 32768) }
}

@Test func integratesKnownSteadySpeedExactlyWithoutDoubleCounting() throws {
    let start = Date()
    let model = SimulationConfiguration(riderMass: 75)
    var simulation = try RideSimulation(configuration: model)
    let speed = try model.speed(watts: 200)
    for second in 0...60 {
        try simulation.sample(watts: 200, uptime: Double(second), activeTime: Double(second),
                              date: start.addingTimeInterval(Double(second)))
    }
    #expect(abs(simulation.metrics.distance - speed * 60) < 0.000001)
    let distance = simulation.metrics.distance
    try simulation.sample(watts: 400, uptime: 60, activeTime: 60, date: start.addingTimeInterval(60))
    try simulation.sample(watts: 400, uptime: 59, activeTime: 59, date: start.addingTimeInterval(59))
    #expect(simulation.metrics.distance == distance)
    #expect(simulation.metrics.speed == speed)
}

@Test func integratesSpeedChangesWithTrapezoidRule() throws {
    let start = Date()
    let model = SimulationConfiguration(riderMass: 75)
    var simulation = try RideSimulation(configuration: model)
    try simulation.sample(watts: 100, uptime: 0, activeTime: 0, date: start)
    try simulation.sample(watts: 200, uptime: 2, activeTime: 2, date: start.addingTimeInterval(2))
    let expected = try model.speed(watts: 100) + model.speed(watts: 200)
    #expect(abs(simulation.metrics.distance - expected) < 0.000001)
}

@Test func simulationNeverBridgesPauseMissingPowerOrLongGaps() throws {
    let start = Date()
    let model = SimulationConfiguration(riderMass: 75)
    var simulation = try RideSimulation(configuration: model)
    try simulation.sample(watts: 200, uptime: 0, activeTime: 0, date: start)
    try simulation.sample(watts: 200, uptime: 1, activeTime: 1, date: start.addingTimeInterval(1))
    let baseline = simulation.metrics.distance
    simulation.suspend()
    #expect(simulation.metrics.speed == nil)
    try simulation.sample(watts: 200, uptime: 100, activeTime: 1, date: start.addingTimeInterval(100))
    #expect(simulation.metrics.distance == baseline)
    try simulation.sample(watts: nil, uptime: 101, activeTime: 2, date: start.addingTimeInterval(101))
    #expect(simulation.metrics.speed == nil)
    try simulation.sample(watts: 200, uptime: 102, activeTime: 3, date: start.addingTimeInterval(102))
    #expect(simulation.metrics.distance == baseline)
    try simulation.sample(watts: 200, uptime: 105.001, activeTime: 6.001, date: start.addingTimeInterval(105.001))
    #expect(simulation.metrics.distance == baseline)
    try simulation.sample(watts: 200, uptime: 108.001, activeTime: 9.001, date: start.addingTimeInterval(108.001))
    #expect(abs(simulation.metrics.distance - baseline * 4) < 0.000001)
}

@Test func replayAfterPauseCannotSeedDuplicateDistance() throws {
    let start = Date()
    var simulation = try RideSimulation(configuration: .init(riderMass: 75))
    try simulation.sample(watts: 200, uptime: 10, activeTime: 0, date: start)
    try simulation.sample(watts: 200, uptime: 11, activeTime: 1, date: start)
    let distance = simulation.metrics.distance
    simulation.suspend()
    try simulation.sample(watts: 200, uptime: 11, activeTime: 1, date: start)
    #expect(simulation.metrics.speed == nil)
    try simulation.sample(watts: 200, uptime: 12, activeTime: 1, date: start)
    #expect(simulation.metrics.distance == distance)
}

@Test func finalSampleIsClippedToActiveWorkoutEnd() throws {
    let model = SimulationConfiguration(riderMass: 75)
    var simulation = try RideSimulation(configuration: model)
    try simulation.sample(watts: 200, uptime: 0, activeTime: 59, date: Date())
    try simulation.sample(watts: 200, uptime: 2, activeTime: 60, date: Date())
    let speed = try model.speed(watts: 200)
    #expect(abs(simulation.metrics.distance - speed) < 0.000001)
}

@Test func invalidTelemetryBreaksSimulationWindowAndRejectsClockReversal() throws {
    var simulation = try RideSimulation(configuration: .init(riderMass: 75))
    try simulation.sample(watts: 200, uptime: 0, activeTime: 0, date: Date())
    try simulation.sample(watts: 200, uptime: 1, activeTime: 1, date: Date())
    let distance = simulation.metrics.distance
    #expect(throws: SimulationError.self) {
        try simulation.sample(watts: 32768, uptime: 2, activeTime: 2, date: Date())
    }
    #expect(simulation.metrics.speed == nil)
    try simulation.sample(watts: 200, uptime: 3, activeTime: 3, date: Date())
    #expect(simulation.metrics.distance == distance)
    #expect(throws: SimulationError.self) {
        try simulation.sample(watts: 200, uptime: 4, activeTime: 1, date: Date())
    }
    #expect(simulation.metrics.speed == nil)
    #expect(simulation.metrics.distance == distance)
}

@Test func sixHourSimulationIsMonotonicAndHasBoundedNumericalDrift() throws {
    let model = SimulationConfiguration(riderMass: 75)
    var simulation = try RideSimulation(configuration: model)
    let start = Date()
    let speed = try model.speed(watts: 200)
    var previous = 0.0
    for second in stride(from: 0, through: 21600, by: 3) {
        let time = Double(second)
        try simulation.sample(watts: 200, uptime: time, activeTime: time, date: start.addingTimeInterval(time))
        #expect(simulation.metrics.distance >= previous)
        previous = simulation.metrics.distance
    }
    #expect(abs(simulation.metrics.distance - speed * 21600) < 0.001)
    #expect(simulation.metrics.isValid)
}

@Test func simulationSnapshotsPersistAndMirrorWithProvenanceAndOptOut() throws {
    let model = SimulationConfiguration(riderMass: 75, saveToHealth: false)
    let saved = try JSONDecoder().decode(SimulationConfiguration.self, from: JSONEncoder().encode(model))
    #expect(saved == model)
    let descriptor = RideDescriptor(id: UUID(), name: "Ride", duration: 60, ftp: 200, simulation: model)
    let received = try JSONDecoder().decode(RideDescriptor.self, from: JSONEncoder().encode(descriptor))
    #expect(received.simulation == model)
    #expect(received.isValid)
    let now = Date()
    let metrics = SimulatedMetrics(speed: 10, distance: 100, date: now)
    let snapshot = RideSnapshot(sequence: 1, state: "running", elapsed: 10, interval: 1, remaining: 50,
        target: 200, power: 190, cadence: 85, telemetryDate: now, status: "Running", simulation: metrics)
    let message = RideMessage(rideID: descriptor.id, action: .snapshot, date: now, snapshot: snapshot)
    let decoded = try RideMessage.decode(JSONEncoder().encode(message), now: now)
    #expect(decoded.snapshot?.simulation?.speed == 10)
    #expect(decoded.snapshot?.simulation?.distance == 100)
    #expect(!SimulatedMetrics(speed: -1, distance: 0, date: now).isValid)
    #expect(!SimulatedMetrics(speed: 1, distance: 0, date: nil).isValid)
    #expect(!SimulatedMetrics(speed: nil, distance: -1, date: nil).isValid)
}

@Test func simulationDoesNotChangeWorkoutCommandsOrTargets() throws {
    let range = try PowerRange.decode(Data([0, 0, 0xD0, 0x07, 1, 0]))
    var plain = try WorkoutPlayback(workout: .sample, ftp: 200, range: range)
    var withSimulation = plain
    var simulation = try RideSimulation(configuration: .init(riderMass: 75))
    let plainBegin = plain.begin()
    let simulatedBegin = withSimulation.begin()
    #expect(plainBegin == simulatedBegin)
    let plainStart = plain.acknowledged(opcode: 5, now: 0)
    let simulatedStart = withSimulation.acknowledged(opcode: 5, now: 0)
    #expect(plainStart == simulatedStart)
    _ = plain.acknowledged(opcode: 7, now: 0)
    _ = withSimulation.acknowledged(opcode: 7, now: 0)
    for second in 0...10 {
        let now = Double(second)
        let plainCommand = plain.service(now: now)
        let simulatedCommand = withSimulation.service(now: now)
        #expect(plainCommand == simulatedCommand)
        try simulation.sample(watts: 30, uptime: now, activeTime: withSimulation.elapsed, date: Date())
        #expect(plain.position == withSimulation.position)
    }
    #expect(simulation.metrics.speed == (try simulation.configuration.speed(watts: 30)))
}
