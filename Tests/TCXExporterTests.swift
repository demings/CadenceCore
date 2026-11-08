import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import TrainerProtocol

private func tcxFixture(saveSimulation: Bool = true) throws -> RideArchive {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var workout = Workout.sample
    workout.name = "A & B <\"test\"> '\u{1}"
    var ride = try RideArchive(workout: workout, ftp: 250,
                               simulation: .init(riderMass: 75, saveToHealth: saveSimulation),
                               trainer: .init(name: "Trainer"), startedAt: start)
    try ride.append(event: .init(state: .running, date: start, activeElapsed: 0))
    for second in 1...2 {
        try ride.append(sample: .init(date: start.addingTimeInterval(Double(second)), activeElapsed: Double(second),
                                     power: 201, cadence: 85, heartRate: 120, target: 999,
                                     simulatedSpeed: 10, simulatedDistance: Double(second) * 10))
    }
    try ride.append(event: .init(state: .paused, date: start.addingTimeInterval(3), activeElapsed: 3))
    try ride.append(event: .init(state: .running, date: start.addingTimeInterval(13), activeElapsed: 3))
    try ride.append(sample: .init(date: start.addingTimeInterval(14), activeElapsed: 4,
                                  power: 202, cadence: 86, heartRate: 121,
                                  simulatedSpeed: 11, simulatedDistance: 31))
    // A missing-telemetry gap must begin a separate track.
    try ride.append(sample: .init(date: start.addingTimeInterval(20), activeElapsed: 10,
                                  target: 999, simulatedDistance: 31))
    try ride.finish(at: start.addingTimeInterval(21), activeElapsed: 11)
    return ride
}

private func nodes(_ document: XMLDocument, _ name: String) throws -> [XMLNode] {
    try document.nodes(forXPath: "//*[local-name()='\(name)']")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CADENCECORE_TCX_SCHEMA"] != nil,
               "Set CADENCECORE_TCX_SCHEMA to a local official TCX + ActivityExtension schema."))
func tcxValidatesAgainstOfficialGarminSchemas() throws {
    let schema = try #require(ProcessInfo.processInfo.environment["CADENCECORE_TCX_SCHEMA"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cadencecore-schema-\(UUID())")
    let file = try TCXExporter.write(tcxFixture(), to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let validation = Process()
    validation.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
    validation.arguments = ["--nonet", "--noout", "--schema", schema, file.path]
    let output = Pipe()
    validation.standardError = output
    try validation.run()
    let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
    validation.waitUntilExit()
    #expect(validation.terminationStatus == 0, "\(String(decoding: diagnostics, as: UTF8.self))")
}

@Test func tcxParsesWithCyclingSIExtensionsNoCoordinatesOrTargetPower() throws {
    let ride = try tcxFixture()
    let xml = try TCXExporter.xml(for: ride)
    let document = try XMLDocument(xmlString: xml)
    #expect(document.rootElement()?.name == "TrainingCenterDatabase")
    #expect(document.rootElement()?.uri == "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2")
    let activity = try #require(nodes(document, "Activity").first as? XMLElement)
    #expect(activity.attribute(forName: "Sport")?.stringValue == "Biking")
    #expect(try nodes(document, "Watts").map(\.stringValue) == ["201", "201", "202"])
    #expect(try nodes(document, "Watts").allSatisfy { $0.uri == "http://www.garmin.com/xmlschemas/ActivityExtension/v2" })
    #expect(try nodes(document, "Speed").first?.stringValue == "10.000000")
    #expect(try nodes(document, "HeartRateBpm").count == 3)
    #expect(try nodes(document, "Cadence").count == 3)
    #expect(try nodes(document, "Trackpoint").count == 4)
    #expect(try nodes(document, "Position").isEmpty)
    #expect(try nodes(document, "LatitudeDegrees").isEmpty)
    #expect(try nodes(document, "AltitudeMeters").isEmpty)
    #expect(try nodes(document, "Time").allSatisfy { $0.stringValue?.hasSuffix("Z") == true })
    #expect(try nodes(document, "Notes").first?.stringValue?.contains("A & B <\"test\"> '") == true)
    #expect(try nodes(document, "Notes").first?.stringValue?.contains("simulated flat-road estimates") == true)
    #expect(!xml.contains("999"))
}

@Test func tcxPauseAndTelemetryGapsStaySeparateAndSummaryUsesActiveTime() throws {
    let ride = try tcxFixture()
    let document = try XMLDocument(xmlString: TCXExporter.xml(for: ride))
    #expect(try nodes(document, "Track").count == 3)
    #expect(try nodes(document, "TotalTimeSeconds").first?.stringValue == "11.000000")
    #expect(ride.elapsedDuration == 21)
    #expect(try nodes(document, "DistanceMeters").first?.stringValue == "31.000000")
    #expect(try nodes(document, "Calories").first?.stringValue == "0")
    #expect(try nodes(document, "Notes").first?.stringValue?.contains("Calories unavailable") == true)
}

@Test func tcxSimulationOptionDefaultsToSnapshotConsentAndCanBeOverridden() throws {
    let ride = try tcxFixture(saveSimulation: false)
    let disabled = try XMLDocument(xmlString: TCXExporter.xml(for: ride))
    #expect(try nodes(disabled, "Speed").isEmpty)
    #expect(try nodes(disabled, "DistanceMeters").count == 1)
    #expect(try nodes(disabled, "DistanceMeters").first?.stringValue == "0.000000")
    #expect(try nodes(disabled, "Notes").first?.stringValue?.contains("Distance unavailable") == true)
    let enabled = try XMLDocument(xmlString: TCXExporter.xml(for: ride, options: .init(includeSimulation: true)))
    #expect(try nodes(enabled, "Speed").count == 3)
    var measured = ride
    try measured.setRecordingMetrics(.init(averageHeartRate: nil, maximumHeartRate: nil,
                                         activeKilocalories: 12.6, restingKilocalories: 2))
    let calories = try XMLDocument(xmlString: TCXExporter.xml(for: measured))
    #expect(try nodes(calories, "Calories").first?.stringValue == "13")
}

@Test func tcxRepeatedExportsHaveStableIdentityAndRealFileURL() throws {
    let ride = try tcxFixture()
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/tcx-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try TCXExporter.write(ride, to: directory)
    let original = try Data(contentsOf: first)
    let second = try TCXExporter.write(ride, to: directory)
    #expect(first == second)
    #expect(first.isFileURL)
    #expect(first.lastPathComponent.contains(ride.id.uuidString))
    #expect(try Data(contentsOf: second) == original)
    let parsed = try XMLDocument(data: original)
    #expect(try nodes(parsed, "Id").first?.stringValue == "2023-11-14T22:13:20.000Z")
    #expect(try nodes(parsed, "Notes").first?.stringValue?.contains(ride.id.uuidString) == true)
}

@Test func tcxCannotExportUnfinishedRideOrInventMeasuredValues() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var ride = try RideArchive(workout: .sample, ftp: 250, trainer: .init(name: "Trainer"), startedAt: start)
    try ride.append(event: .init(state: .running, date: start, activeElapsed: 0))
    #expect(throws: RideArchiveError.self) { try TCXExporter.xml(for: ride) }
    var empty = ride
    try empty.finish(at: start.addingTimeInterval(2), activeElapsed: 2)
    #expect(throws: RideArchiveError.self) { try TCXExporter.xml(for: empty) }
    try ride.append(sample: .init(date: start.addingTimeInterval(1), activeElapsed: 1,
                                  power: -1, cadence: 300, heartRate: 300, target: 999))
    var unrepresentable = ride
    try unrepresentable.finish(at: start.addingTimeInterval(2), activeElapsed: 2)
    #expect(throws: RideArchiveError.self) { try TCXExporter.xml(for: unrepresentable) }
    try ride.append(sample: .init(date: start.addingTimeInterval(2), activeElapsed: 2, power: 1))
    try ride.finish(at: start.addingTimeInterval(3), activeElapsed: 3)
    let document = try XMLDocument(xmlString: TCXExporter.xml(for: ride))
    #expect(try nodes(document, "Watts").map(\.stringValue) == ["1"])
    #expect(try nodes(document, "Cadence").isEmpty)
    #expect(try nodes(document, "HeartRateBpm").isEmpty)
    #expect(try nodes(document, "Speed").isEmpty)
    #expect(try nodes(document, "Notes").first?.stringValue?.contains("cadence above 254 rpm and heart rate above 255 bpm") == true)
    try ride.setRecordingMetrics(.init(averageHeartRate: nil, maximumHeartRate: nil,
                                      activeKilocalories: 65536, restingKilocalories: nil))
    #expect(throws: RideArchiveError.self) { try TCXExporter.xml(for: ride) }
}

@Test func tcxZeroActiveDeltaSplitsTrackEvenWhenWallGapIsSmall() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var ride = try RideArchive(workout: .sample, ftp: 250, trainer: .init(name: "Trainer"), startedAt: start)
    try ride.append(event: .init(state: .running, date: start, activeElapsed: 0))
    try ride.append(sample: .init(date: start.addingTimeInterval(1), activeElapsed: 1, power: 200))
    try ride.append(sample: .init(date: start.addingTimeInterval(1.5), activeElapsed: 1, power: 200))
    try ride.finish(at: start.addingTimeInterval(2), activeElapsed: 1.5)
    let document = try XMLDocument(xmlString: TCXExporter.xml(for: ride))
    #expect(try nodes(document, "Track").count == 2)
}
