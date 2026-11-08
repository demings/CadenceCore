import Foundation
import Testing
@testable import TrainerProtocol

private let archiveStart = Date(timeIntervalSince1970: 1_700_000_000)

private func archiveFixture(id: UUID = UUID()) throws -> RideArchive {
    var ride = try RideArchive(id: id, workout: .sample, ftp: 250,
                               simulation: .init(riderMass: 75),
                               trainer: .init(id: UUID(), name: "Trainer"), startedAt: archiveStart)
    try ride.append(event: .init(state: .running, date: archiveStart, activeElapsed: 0))
    return ride
}

private func archiveTestDirectory() throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/archive-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func archivePausedIntensityAndFinalDistanceSurviveWithoutExtraTelemetry() throws {
    var ride = try archiveFixture()
    try ride.append(sample: .init(date: archiveStart.addingTimeInterval(1), activeElapsed: 1,
        power: 200, simulatedDistance: 10))
    try ride.append(event: .init(state: .paused, date: archiveStart.addingTimeInterval(2), activeElapsed: 2,
        intensity: 1, simulatedDistance: 12))
    try ride.append(event: .init(state: .paused, date: archiveStart.addingTimeInterval(3), activeElapsed: 2,
        intensity: 1.2, simulatedDistance: 12))
    let restored = try JSONDecoder().decode(RideArchive.self, from: JSONEncoder().encode(ride))
    try restored.validate()
    #expect(restored.currentIntensity == 1.2)
    #expect(restored.simulatedDistance == 12)
    #expect(restored.activeDuration == 2)
}

@Test func archiveRetainsOriginalFreshHeartRateTimestampAndRejectsStaleAlignment() throws {
    var ride = try archiveFixture()
    try ride.append(sample: .init(date: archiveStart.addingTimeInterval(2), activeElapsed: 2,
        power: 200, heartRate: 120, heartRateSampleDate: archiveStart.addingTimeInterval(1)))
    #expect(ride.samples[0].heartRateSampleDate == archiveStart.addingTimeInterval(1))
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(date: archiveStart.addingTimeInterval(10), activeElapsed: 10,
            heartRate: 120, heartRateSampleDate: archiveStart.addingTimeInterval(5)))
    }
}

@Test func archiveOnlyRewritesChangedRideAndDetectsMissingTelemetryFile() throws {
    let directory = try archiveTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = RideArchiveRepository(directory: directory)
    try repository.load()
    let first = try archiveFixture()
    var second = try archiveFixture()
    try repository.save(first)
    try repository.save(second)
    let firstFile = directory.appendingPathComponent("Rides/\(first.id.uuidString).json")
    let original = try FileManager.default.attributesOfItem(atPath: firstFile.path)[.modificationDate] as? Date
    let manifest = try Data(contentsOf: repository.fileURL)
    try second.append(sample: .init(date: archiveStart.addingTimeInterval(1), activeElapsed: 1, power: 200))
    try repository.save(second)
    #expect(try FileManager.default.attributesOfItem(atPath: firstFile.path)[.modificationDate] as? Date == original)
    #expect(try Data(contentsOf: repository.fileURL) == manifest)
    let restart = RideArchiveRepository(directory: directory)
    try restart.load()
    #expect(restart.rides.first(where: { $0.id == second.id })?.samples.count == 1)
    try FileManager.default.removeItem(at: firstFile)
    let broken = RideArchiveRepository(directory: directory)
    #expect(throws: RideArchiveError.self) { try broken.load() }
    #expect(throws: RideArchiveError.self) { try broken.save(second) }
}

@Test func archivePersistsRestartRecoveryAndHealthReceipt() throws {
    let directory = try archiveTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = RideArchiveRepository(directory: directory)
    try repository.load()
    var ride = try archiveFixture()
    try ride.append(sample: .init(date: archiveStart.addingTimeInterval(1), activeElapsed: 1,
                                  power: 220, cadence: 85, heartRate: 120, target: 250,
                                  interval: 1, intensity: 1.1, simulatedSpeed: 9, simulatedDistance: 9))
    try repository.save(ride)
    let restart = RideArchiveRepository(directory: directory)
    try restart.load()
    #expect(restart.rides.count == 1)
    #expect(restart.rides[0].isRecoverable)
    #expect(restart.rides[0].samples == ride.samples)
    #expect(restart.rides[0].workout == ride.workout)
    #expect(restart.rides[0].samples[0].intensity == 1.1)
    try ride.finish(at: archiveStart.addingTimeInterval(2), activeElapsed: 2)
    let healthID = UUID()
    try ride.setHealthReceipt(.init(status: .failed, detail: "Save outcome was initially unconfirmed."))
    try ride.setHealthReceipt(.init(status: .saved, workoutID: healthID))
    #expect(throws: RideArchiveError.self) {
        try ride.setHealthReceipt(.init(status: .saved, workoutID: UUID()))
    }
    #expect(throws: RideArchiveError.self) { try ride.setHealthReceipt(.init(status: .failed)) }
    try ride.setRecordingMetrics(.init(averageHeartRate: 120, maximumHeartRate: 125,
                                      activeKilocalories: 10, restingKilocalories: 2))
    try restart.save(ride)
    let finishedRestart = RideArchiveRepository(directory: directory)
    try finishedRestart.load()
    #expect(!finishedRestart.rides[0].isRecoverable)
    #expect(finishedRestart.rides[0].healthReceipt.workoutID == healthID)
    #expect(finishedRestart.rides[0].recordingMetrics?.totalKilocalories == 12)
    try finishedRestart.delete(id: ride.id)
    let deletedRestart = RideArchiveRepository(directory: directory)
    try deletedRestart.load()
    #expect(deletedRestart.rides.isEmpty)
}

@Test func archiveDeduplicatesAndRejectsConflictingIdentities() throws {
    var ride = try archiveFixture()
    let sample = RideArchiveSample(date: archiveStart.addingTimeInterval(1), activeElapsed: 1, power: 200)
    #expect(try ride.append(sample: sample))
    #expect(try !ride.append(sample: sample))
    #expect(try !ride.append(sample: .init(date: sample.date, activeElapsed: 1, power: 200)))
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(id: sample.id, date: sample.date, activeElapsed: 1, power: 201))
    }
    let directory = try archiveTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = RideArchiveRepository(directory: directory)
    try repository.load(); try repository.save(ride)
    let conflicting = try archiveFixture(id: ride.id)
    #expect(throws: RideArchiveError.self) { try repository.save(conflicting) }
    #expect(repository.rides[0].samples.count == 1)
}

@Test func archiveRejectsInvalidSamplesAndPausedTimeCreditWithoutMutation() throws {
    var ride = try archiveFixture()
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(date: archiveStart.addingTimeInterval(1), activeElapsed: 1, cadence: .nan))
    }
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(date: archiveStart.addingTimeInterval(1), activeElapsed: 1, heartRate: 0))
    }
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(date: archiveStart.addingTimeInterval(1), activeElapsed: 1, intensity: 2))
    }
    #expect(ride.samples.isEmpty)
    try ride.append(event: .init(state: .paused, date: archiveStart.addingTimeInterval(10), activeElapsed: 10))
    #expect(ride.elapsedDuration == 10)
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(date: archiveStart.addingTimeInterval(11), activeElapsed: 11, power: 100))
    }
    #expect(throws: RideArchiveError.self) {
        try ride.append(event: .init(state: .running, date: archiveStart.addingTimeInterval(20), activeElapsed: 20))
    }
    try ride.append(event: .init(state: .running, date: archiveStart.addingTimeInterval(20), activeElapsed: 10))
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(date: archiveStart.addingTimeInterval(21), activeElapsed: 21, power: 100))
    }
    try ride.finish(at: archiveStart.addingTimeInterval(30), activeElapsed: 20)
    #expect(ride.activeDuration == 20)
    #expect(ride.elapsedDuration == 30)
}

@Test func archiveDistanceCannotDecreaseAcrossUnavailableSample() throws {
    var ride = try archiveFixture()
    try ride.append(sample: .init(date: archiveStart.addingTimeInterval(1), activeElapsed: 1, simulatedDistance: 10))
    try ride.append(sample: .init(date: archiveStart.addingTimeInterval(2), activeElapsed: 2))
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(date: archiveStart.addingTimeInterval(3), activeElapsed: 3, simulatedDistance: 9))
    }

    #expect(ride.samples.count == 2)
}

@Test func archiveOptionalCadenceAndIntensitySnapshotsAreValidatedAndBackwardCompatible() throws {
        let ride = try RideArchive(workout: .sample, ftp: 250, trainer: .init(name: "Trainer"),
                                   cadenceConfiguration: .defaults, initialIntensity: 1.2)
        let decoded = try JSONDecoder().decode(RideArchive.self, from: JSONEncoder().encode(ride))
        #expect(decoded.cadenceConfiguration == .defaults)
        #expect(decoded.initialIntensity == 1.2)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ride)) as? [String: Any])
        legacy.removeValue(forKey: "cadenceConfiguration")
        legacy.removeValue(forKey: "initialIntensity")
        let restored = try JSONDecoder().decode(RideArchive.self, from: JSONSerialization.data(withJSONObject: legacy))
        try restored.validate()
        #expect(restored.cadenceConfiguration == nil)
        #expect(restored.initialIntensity == nil)
        #expect(throws: RideArchiveError.self) {
            try RideArchive(workout: .sample, ftp: 250, trainer: .init(name: "Trainer"),
                            cadenceConfiguration: .init(easy: .init(lower: 100, upper: 50)))
        }
        #expect(throws: RideArchiveError.self) {
            try RideArchive(workout: .sample, ftp: 250, trainer: .init(name: "Trainer"), initialIntensity: 2)
        }
}

@Test func archiveCorruptionIsExplicitAndCannotBeOverwritten() throws {
    let directory = try archiveTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = RideArchiveRepository(directory: directory)
    let damaged = Data("not JSON".utf8)
    try damaged.write(to: repository.fileURL)
    #expect(throws: RideArchiveError.self) { try repository.load() }
    #expect(throws: RideArchiveError.self) { try repository.save(archiveFixture()) }
    #expect(throws: RideArchiveError.self) { try repository.delete(id: UUID()) }
    #expect(try Data(contentsOf: repository.fileURL) == damaged)
}

@Test func archivePersistenceFailureDoesNotClaimSaved() throws {
    let directory = try archiveTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocked = directory.appendingPathComponent("regular-file")
    try Data().write(to: blocked)
    let repository = RideArchiveRepository(directory: blocked)
    try repository.load()
    #expect(throws: RideArchiveError.self) { try repository.save(archiveFixture()) }
    #expect(repository.rides.isEmpty)
    let unloaded = RideArchiveRepository(directory: directory)
    #expect(throws: RideArchiveError.self) { try unloaded.save(archiveFixture()) }
}

@Test func archiveBoundsRideAndSixHourSampleHistory() throws {
    let directory = try archiveTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = RideArchiveRepository(directory: directory)
    try repository.load()
    for _ in 0..<RideArchiveRepository.maximumRides { try repository.save(archiveFixture()) }
    #expect(throws: RideArchiveError.self) { try repository.save(archiveFixture()) }
    #expect(repository.rides.count == RideArchiveRepository.maximumRides)

    var ride = try archiveFixture()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ride)) as? [String: Any])
    object["samples"] = try (0..<RideArchive.maximumSamples).map { second in
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(RideArchiveSample(
            date: archiveStart.addingTimeInterval(Double(second)), activeElapsed: Double(second), power: 200)))
    }
    ride = try JSONDecoder().decode(RideArchive.self, from: JSONSerialization.data(withJSONObject: object))
    try ride.validate()
    #expect(ride.samples.count == 21600)
    #expect(throws: RideArchiveError.self) {
        try ride.append(sample: .init(date: archiveStart.addingTimeInterval(21600), activeElapsed: 21600, power: 200))
    }
}
