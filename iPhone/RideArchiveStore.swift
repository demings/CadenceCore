import Foundation
import Observation

@MainActor @Observable
final class RideArchiveStore {
    private(set) var rides: [RideArchive] = []
    private(set) var error: String?
    private(set) var loaded = false
    private let repository: RideArchiveRepository
    var onDelete: ((UUID) -> Void)?

    var recoverableRides: [RideArchive] { rides.filter(\.isRecoverable) }
    var exportDirectory: URL { repository.directory.appendingPathComponent("Exports", isDirectory: true) }

    init(directory: URL? = nil) {
        let base = directory ?? URL.applicationSupportDirectory.appendingPathComponent("CadenceCore/RideHistory", isDirectory: true)
        repository = RideArchiveRepository(directory: base)
        do {
            try repository.load()
            rides = repository.rides
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    func ride(id: UUID) -> RideArchive? { rides.first { $0.id == id } }

    func save(_ ride: RideArchive) throws {
        do {
            try repository.save(ride)
            rides = repository.rides
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    @discardableResult func append(sample: RideArchiveSample, to id: UUID) throws -> Bool {
        try update(id: id) { try $0.append(sample: sample) }
    }

    @discardableResult func append(event: RideArchiveEvent, to id: UUID) throws -> Bool {
        try update(id: id) { try $0.append(event: event) }
    }

    func finish(id: UUID, at date: Date, activeElapsed: Double) throws {
        try update(id: id) { try $0.finish(at: date, activeElapsed: activeElapsed) }
    }

    func setHealthReceipt(_ receipt: RideHealthReceipt, for id: UUID) throws {
        try update(id: id) { try $0.setHealthReceipt(receipt) }
    }

    func setRecordingMetrics(_ metrics: RecordingMetrics?, for id: UUID) throws {
        try update(id: id) { try $0.setRecordingMetrics(metrics) }
    }

    func delete(id: UUID) throws {
        do {
            let export = exportDirectory.appendingPathComponent("CadenceCore-\(id.uuidString).tcx")
            if FileManager.default.fileExists(atPath: export.path) { try FileManager.default.removeItem(at: export) }
            try repository.delete(id: id)
            rides = repository.rides
            error = nil
            onDelete?(id)
        } catch {
            rides = repository.rides
            if ride(id: id) == nil { onDelete?(id) }
            self.error = error.localizedDescription
            throw error
        }
    }

    func export(id: UUID, includeSimulation: Bool) throws -> URL {
        guard let ride = ride(id: id) else { throw RideArchiveError.invalid("Ride not found.") }
        do {
            return try TCXExporter.write(
                ride, to: exportDirectory,
                options: .init(includeSimulation: includeSimulation))
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private func update<T>(id: UUID, _ change: (inout RideArchive) throws -> T) throws -> T {
        do {
            guard var ride = ride(id: id) else { throw RideArchiveError.invalid("Ride not found.") }
            let result = try change(&ride)
            try save(ride)
            return result
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
}
