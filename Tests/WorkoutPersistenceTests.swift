import Foundation
import SwiftData
import Testing
@testable import TrainerProtocol

@Test @MainActor func libraryStoresEditsAndDeletesWorkouts() throws {
    let container = try ModelContainer(
        for: SavedWorkout.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    let saved = try SavedWorkout(workout: .sample, source: Data("original".utf8))
    context.insert(saved)
    try context.save()
    saved.name = "Renamed"
    saved.favorite = true
    try context.save()
    let rows = try context.fetch(FetchDescriptor<SavedWorkout>())
    #expect(rows.count == 1)
    #expect(rows[0].name == "Renamed")
    #expect(rows[0].favorite)
    #expect(rows[0].source == Data("original".utf8))
    #expect(try JSONDecoder().decode(Workout.self, from: rows[0].encodedWorkout) == Workout.sample)
    context.delete(saved)
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<SavedWorkout>()) == 0)
}

@Test @MainActor func librarySurvivesReopeningPersistentStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CadenceCore-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Cannot clean test store: \(error.localizedDescription)") }
    }
    let url = directory.appendingPathComponent("workouts.store")
    let configuration = ModelConfiguration(url: url)
    let first = try ModelContainer(for: SavedWorkout.self, configurations: configuration)
    let writeContext = ModelContext(first)
    writeContext.insert(try SavedWorkout(workout: .sample, source: nil))
    try writeContext.save()

    let reopened = try ModelContainer(for: SavedWorkout.self, configurations: ModelConfiguration(url: url))
    let rows = try ModelContext(reopened).fetch(FetchDescriptor<SavedWorkout>())
    #expect(rows.count == 1)
    #expect(rows.first?.name == Workout.sample.name)
    #expect(try rows.first.map { try JSONDecoder().decode(Workout.self, from: $0.encodedWorkout) } == Workout.sample)
}
