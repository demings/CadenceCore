import Foundation
import Testing
@testable import TrainerProtocol

private func xml(_ blocks: String, metadata: String = "<sportType>bike</sportType>") -> Data {
    Data("<workout_file><name>Test &amp; Ride</name>\(metadata)<workout>\(blocks)</workout></workout_file>".utf8)
}

@Test func importsRampsAndRepeatCadence() throws {
    let workout = try ZWOImporter.parse(xml("""
    <Warmup Duration="60" PowerLow="0.4" PowerHigh="0.6"/>
    <IntervalsT Repeat="2" OnDuration="30" OffDuration="20" OnPower="1.1" OffPower="0.5" Cadence="95" CadenceResting="75"/>
    <Cooldown Duration="60" PowerLow="0.6" PowerHigh="0.3"/>
    """))
    #expect(workout.name == "Test & Ride")
    #expect(workout.duration == 220)
    #expect(workout.intervals.count == 6)
    #expect(workout.intervals[1].cadence == 95)
    #expect(workout.intervals[2].cadence == 75)
    #expect(workout.intervals[0].watts(at: 30, ftp: 200) == 100)
    #expect(workout.intervals.last?.watts(at: 60, ftp: 200) == 60)
}

@Test func rejectsUnsafeAndUnsupportedImports() {
    for block in [
        "<FreeRide Duration=\"30\"/>",
        "<SteadyState Duration=\"NaN\" Power=\"0.5\"/>",
        "<SteadyState Duration=\"0\" Power=\"0.5\"/>",
        "<SteadyState Duration=\"30\" Power=\"Infinity\"/>",
        "<SteadyState Duration=\"30\" Power=\"3.1\"/>",
        "<SteadyState Duration=\"30\" Power=\"0.5\" Cadence=\"0\"/>",
        "<SteadyState Duration=\"30\" Power=\"0.5\" FlatRoad=\"1\"/>",
        "<IntervalsT Repeat=\"1.5\" OnDuration=\"30\" OffDuration=\"30\" OnPower=\"1\" OffPower=\"0.5\"/>",
        "<SteadyState Duration=\"21601\" Power=\"0.5\"/>",
        "<SteadyState Duration=\"12000\" Power=\"0.5\"/><SteadyState Duration=\"12000\" Power=\"0.5\"/>"
    ] {
        #expect(throws: WorkoutImportError.self) { try ZWOImporter.parse(xml(block)) }
    }
    #expect(throws: WorkoutImportError.self) { try ZWOImporter.parse(xml("", metadata: "<sportType>run</sportType>")) }
    #expect(throws: WorkoutImportError.self) { try ZWOImporter.parse(Data()) }
    #expect(throws: WorkoutImportError.self) { try ZWOImporter.parse(Data(repeating: 32, count: ZWOImporter.maximumFileBytes + 1)) }
    #expect(throws: WorkoutImportError.self) { try ZWOImporter.parse(Data("<workout_file>".utf8)) }
    #expect(throws: WorkoutImportError.self) {
        try ZWOImporter.parse(Data("<!DOCTYPE workout_file [<!ENTITY x \"hi\">]><workout_file><name>&x;</name><workout><SteadyState Duration=\"1\" Power=\"1\"/></workout></workout_file>".utf8))
    }
}

@Test func enforcesExpandedIntervalLimitAndReportsWarnings() throws {
    let repeatBlock = "<IntervalsT Repeat=\"1000\" OnDuration=\"1\" OffDuration=\"1\" OnPower=\"1\" OffPower=\"0.5\"/>"
    #expect(try ZWOImporter.parse(xml(repeatBlock)).intervals.count == 2000)
    #expect(throws: WorkoutImportError.self) {
        try ZWOImporter.parse(xml(repeatBlock + "<SteadyState Duration=\"1\" Power=\"1\"/>"))
    }

    let workout = try ZWOImporter.parse(xml("<SteadyState Duration=\"1\" Power=\"1\" CadenceLow=\"80\"><textevent timeoffset=\"0\" message=\"Hello\"/></SteadyState>"))
    #expect(workout.warnings.count == 2)
    #expect(workout.intervals[0].cadence == nil)
}

@Test func durationAndNestingLimitsAreExact() throws {
    #expect(try ZWOImporter.parse(xml("<SteadyState Duration=\"21600\" Power=\"0\"/>")).duration == 21600)
    let nested = String(repeating: "<tag>", count: 17) + String(repeating: "</tag>", count: 17)
    #expect(throws: WorkoutImportError.self) {
        try ZWOImporter.parse(xml("<SteadyState Duration=\"1\" Power=\"1\"/>", metadata: "<tags>\(nested)</tags>"))
    }
    #expect(throws: WorkoutImportError.self) {
        try ZWOImporter.parse(xml("<SteadyState Duration=\"1\" Power=\"1\"><unknown/></SteadyState>"))
    }
    #expect(throws: WorkoutImportError.self) {
        try ZWOImporter.parse(Data("<workout_file><name>Test</name><workout><SteadyState Duration=\"1\" Power=\"1\"/></workout><workout><SteadyState Duration=\"1\" Power=\"1\"/></workout></workout_file>".utf8))
    }
}

@Test func normalizedWorkoutsRoundTripForPersistence() throws {
    let workout = try ZWOImporter.parse(xml("<Ramp Duration=\"60\" PowerLow=\"0.5\" PowerHigh=\"1\" Cadence=\"90\"/>"))
    #expect(try JSONDecoder().decode(Workout.self, from: JSONEncoder().encode(workout)) == workout)
    #expect(try JSONDecoder().decode(Workout.self, from: JSONEncoder().encode(Workout.sample)) == Workout.sample)
    #expect(workout.intervals[0].watts(at: -1, ftp: 200) == 100)
    #expect(workout.intervals[0].watts(at: 100, ftp: 200) == 200)
}
