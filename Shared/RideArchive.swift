import Foundation

public enum RideArchiveError: Error, LocalizedError {
    case invalid(String)
    case capacity, duplicateIdentity
    case corrupt(String)
    case persistence(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "Invalid ride history: \(detail)"
        case .capacity: "Ride history limit reached. Delete an older completed ride or end this ride."
        case .duplicateIdentity: "A conflicting ride or sample already uses this identity."
        case .corrupt(let detail):
            "Ride history could not be loaded; existing files were preserved. \(detail)"
        case .persistence(let detail): "Ride history was not saved: \(detail)"
        }
    }
}

public struct RideTrainerIdentity: Codable, Equatable, Sendable {
    public let id: UUID?
    public let name: String
    public init(id: UUID? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RideArchiveEvent: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, paused, interrupted, finished }
    public let id: UUID
    public let state: State
    public let date: Date
    public let activeElapsed: Double
    public let intensity: Double?
    public let simulatedDistance: Double?
    public init(
        id: UUID = UUID(), state: State, date: Date, activeElapsed: Double,
        intensity: Double? = nil, simulatedDistance: Double? = nil
    ) {
        self.id = id
        self.state = state
        self.date = date
        self.activeElapsed = activeElapsed
        self.intensity = intensity
        self.simulatedDistance = simulatedDistance
    }
}

public struct RideArchiveSample: Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let activeElapsed: Double
    public let power: Int?
    public let cadence: Double?
    public let heartRate: Double?
    public let heartRateSampleDate: Date?
    public let target: Int?
    public let interval: Int?
    public let intensity: Double
    public let simulatedSpeed: Double?
    public let simulatedDistance: Double?
    public init(
        id: UUID = UUID(), date: Date, activeElapsed: Double, power: Int? = nil,
        cadence: Double? = nil, heartRate: Double? = nil, target: Int? = nil,
        interval: Int? = nil, intensity: Double = 1, simulatedSpeed: Double? = nil,
        simulatedDistance: Double? = nil,
        heartRateSampleDate: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.activeElapsed = activeElapsed
        self.power = power
        self.cadence = cadence
        self.heartRate = heartRate
        self.target = target
        self.interval = interval
        self.heartRateSampleDate = heartRateSampleDate
        self.intensity = intensity
        self.simulatedSpeed = simulatedSpeed
        self.simulatedDistance = simulatedDistance
    }
}

public struct RideHealthReceipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, saved, failed, unavailable }
    public let status: Status
    public let workoutID: UUID?
    public let detail: String?
    public init(status: Status, workoutID: UUID? = nil, detail: String? = nil) {
        self.status = status
        self.workoutID = workoutID
        self.detail = detail
    }
}

public struct RideArchive: Codable, Sendable, Identifiable {
    public enum RecordingMode: String, Codable, Sendable { case watch, iPhone }
    public static let maximumSamples = 21_600
    public static let maximumEvents = 2_048
    public let version: Int
    public let id: UUID
    public let workout: Workout
    public let ftp: Double
    public let simulation: SimulationConfiguration?
    public let cadenceConfiguration: CadenceConfiguration?
    public let initialIntensity: Double?
    public let trainer: RideTrainerIdentity
    public let recordingMode: RecordingMode
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var events: [RideArchiveEvent]
    public private(set) var samples: [RideArchiveSample]
    public private(set) var recordingMetrics: RecordingMetrics?
    public private(set) var healthReceipt: RideHealthReceipt
    public var activeDuration: Double {
        max(events.last?.activeElapsed ?? 0, samples.last?.activeElapsed ?? 0)
    }
    public var elapsedDuration: Double {
        (endedAt ?? max(samples.last?.date ?? startedAt, events.last?.date ?? startedAt))
            .timeIntervalSince(startedAt)
    }
    public var isRecoverable: Bool { endedAt == nil }
    public var simulatedDistance: Double? {
        [events.last?.simulatedDistance, samples.last?.simulatedDistance].compactMap { $0 }.max()
    }
    public var currentIntensity: Double {
        let event = events.last
        let sample = samples.last
        if let event, let intensity = event.intensity,
            sample.map({ event.date >= $0.date }) ?? true
        {
            return intensity
        }
        return sample?.intensity ?? initialIntensity ?? 1
    }

    public init(
        id: UUID = UUID(), workout: Workout, ftp: Double, simulation: SimulationConfiguration? = nil,
        trainer: RideTrainerIdentity, startedAt: Date = Date(), recordingMode: RecordingMode = .watch,
        cadenceConfiguration: CadenceConfiguration? = nil, initialIntensity: Double? = nil
    ) throws {
        version = 1
        self.id = id
        self.workout = workout
        self.ftp = ftp
        self.simulation = simulation
        self.trainer = trainer
        self.startedAt = startedAt
        endedAt = nil
        events = []
        samples = []
        self.recordingMode = recordingMode
        self.cadenceConfiguration = cadenceConfiguration
        self.initialIntensity = initialIntensity
        recordingMetrics = nil
        healthReceipt = .init(status: .pending)
        try validate()
    }

    @discardableResult public mutating func append(sample: RideArchiveSample) throws -> Bool {
        if let existing = samples.first(where: { $0.id == sample.id }) {
            guard existing == sample else { throw RideArchiveError.duplicateIdentity }
            return false
        }
        // Telemetry timestamps also deduplicate replayed packets with newly assigned IDs.
        if let existing = samples.first(where: { $0.date == sample.date }) {
            guard existing.activeElapsed == sample.activeElapsed, existing.power == sample.power,
                existing.cadence == sample.cadence, existing.heartRate == sample.heartRate,
                existing.heartRateSampleDate == sample.heartRateSampleDate,
                existing.target == sample.target, existing.interval == sample.interval,
                existing.intensity == sample.intensity,
                existing.simulatedSpeed == sample.simulatedSpeed,
                existing.simulatedDistance == sample.simulatedDistance
            else { throw RideArchiveError.duplicateIdentity }
            return false
        }
        guard samples.count < Self.maximumSamples else { throw RideArchiveError.capacity }
        guard endedAt == nil else { throw RideArchiveError.invalid("Ride has ended.") }
        var candidate = self
        candidate.samples.append(sample)
        try candidate.validate()
        self = candidate
        return true
    }

    @discardableResult public mutating func append(event: RideArchiveEvent) throws -> Bool {
        if let existing = events.first(where: { $0.id == event.id }) {
            guard existing == event else { throw RideArchiveError.duplicateIdentity }
            return false
        }
        guard events.count < Self.maximumEvents else { throw RideArchiveError.capacity }
        guard endedAt == nil else { throw RideArchiveError.invalid("Ride has ended.") }
        var candidate = self
        candidate.events.append(event)
        if event.state == .finished { candidate.endedAt = event.date }
        try candidate.validate()
        self = candidate
        return true
    }

    public mutating func finish(at date: Date, activeElapsed: Double) throws {
        if endedAt == date, activeDuration == activeElapsed { return }
        try append(event: .init(state: .finished, date: date, activeElapsed: activeElapsed))
    }

    public mutating func setHealthReceipt(_ receipt: RideHealthReceipt) throws {
        if healthReceipt.status == .saved {
            guard receipt.status == .saved,
                healthReceipt.workoutID == nil || healthReceipt.workoutID == receipt.workoutID
            else {
                throw RideArchiveError.duplicateIdentity
            }
        }
        var candidate = self
        candidate.healthReceipt = receipt
        try candidate.validate()
        self = candidate
    }

    public mutating func setRecordingMetrics(_ metrics: RecordingMetrics?) throws {
        guard metrics.map(\.isValid) ?? true else {
            throw RideArchiveError.invalid("Recording metrics.")
        }
        recordingMetrics = metrics
    }

    /// Recording completion does not confirm trainer stop; the live coordinator retains safety ownership.
    public mutating func concludeRecording(
        receipt: RideHealthReceipt, at date: Date,
        metrics: RecordingMetrics? = nil, lastConfirmedDistance: Double? = nil
    ) throws {
        guard recordingMode == .watch, receipt.status != .pending, date.timeIntervalSince1970.isFinite,
            lastConfirmedDistance.map({ $0.isFinite && $0 >= 0 }) ?? true
        else {
            throw RideArchiveError.invalid("Terminal recording receipt.")
        }
        var candidate = self
        try candidate.setHealthReceipt(receipt)
        if let metrics { try candidate.setRecordingMetrics(metrics) }
        if candidate.isRecoverable {
            let end = max(date, max(candidate.events.last?.date ?? startedAt, candidate.samples.last?.date ?? startedAt))
            let distance = [candidate.simulatedDistance, lastConfirmedDistance].compactMap { $0 }.max()
            try candidate.append(
                event: .init(
                    state: .finished, date: end, activeElapsed: candidate.activeDuration,
                    intensity: candidate.currentIntensity, simulatedDistance: distance))
        }
        self = candidate
    }

    public func validate() throws {
        func valid(_ value: Double?, _ range: ClosedRange<Double>) -> Bool {
            value.map { $0.isFinite && range.contains($0) } ?? true
        }
        guard version == 1, valid(startedAt.timeIntervalSince1970, 0...253_402_300_799),
            workout.isValid,
            !workout.name.isEmpty, workout.name.utf8.count <= 4096,
            workout.description.utf8.count <= 65_536, workout.warnings.count <= 2048,
            workout.warnings.allSatisfy({ $0.utf8.count <= 4096 }),
            !workout.intervals.isEmpty, workout.intervals.count <= 2048,
            valid(workout.duration, 0.001...21600), valid(ftp, 1...2000),
            cadenceConfiguration.map(\.isValid) ?? true, valid(initialIntensity, 0.5...1.5),
            simulation.map(\.isValid) ?? true, !trainer.name.isEmpty, trainer.name.utf8.count <= 4096,
            samples.count <= Self.maximumSamples, events.count <= Self.maximumEvents,
            recordingMetrics.map(\.isValid) ?? true,
            (healthReceipt.detail?.utf8.count ?? 0) <= 8192,
            healthReceipt.status == .saved || healthReceipt.workoutID == nil
        else {
            throw RideArchiveError.invalid("Metadata, size, or recording receipt.")
        }
        var previousEvent: RideArchiveEvent?
        var previousEventDistance: Double?
        var eventIDs = Set<UUID>()
        for event in events {
            guard eventIDs.insert(event.id).inserted,
                valid(event.date.timeIntervalSince1970, 0...253_402_300_799),
                event.date >= startedAt, valid(event.activeElapsed, 0...workout.duration),
                valid(event.intensity, 0.5...1.5), valid(event.simulatedDistance, 0...4_320_000),
                simulation != nil || event.simulatedDistance == nil,
                event.activeElapsed <= event.date.timeIntervalSince(startedAt) + 1,
                previousEvent.map({
                    $0.state != .finished && event.date >= $0.date && event.activeElapsed >= $0.activeElapsed
                        && event.activeElapsed - $0.activeElapsed <= event.date.timeIntervalSince($0.date) + 1
                        && ($0.state == .running || event.activeElapsed == $0.activeElapsed)
                }) ?? (event.activeElapsed == 0)
            else {
                throw RideArchiveError.invalid("Event timeline.")
            }
            previousEvent = event
            if let distance = event.simulatedDistance {
                guard previousEventDistance.map({ distance >= $0 }) ?? true else {
                    throw RideArchiveError.invalid("Event distance must not decrease.")
                }
                previousEventDistance = distance
            }
        }
        guard endedAt == (events.last?.state == .finished ? events.last?.date : nil) else {
            throw RideArchiveError.invalid("Completion timestamp.")
        }
        var previousSample: RideArchiveSample?
        var previousDistance: Double?
        var sampleIDs = Set<UUID>()
        var eventIndex = 0
        for sample in samples {
            while eventIndex + 1 < events.count && events[eventIndex + 1].date <= sample.date {
                eventIndex += 1
            }
            guard sampleIDs.insert(sample.id).inserted,
                valid(sample.date.timeIntervalSince1970, 0...253_402_300_799),
                sample.date >= startedAt, endedAt.map({ sample.date <= $0 }) ?? true,
                valid(sample.activeElapsed, 0...workout.duration),
                sample.activeElapsed <= sample.date.timeIntervalSince(startedAt) + 1,
                sample.power.map({ (-32768...32767).contains($0) }) ?? true,
                valid(sample.cadence, 0...1000), valid(sample.heartRate, 1...300),
                sample.heartRateSampleDate.map({
                    sample.heartRate != nil && (0...3).contains(sample.date.timeIntervalSince($0))
                }) ?? true,
                sample.target.map({ (0...32767).contains($0) }) ?? true,
                valid(sample.intensity, 0.5...1.5),
                sample.interval.map({ (1...workout.intervals.count).contains($0) }) ?? true,
                valid(sample.simulatedSpeed, 0...200), valid(sample.simulatedDistance, 0...4_320_000),
                simulation != nil || (sample.simulatedSpeed == nil && sample.simulatedDistance == nil),
                sample.simulatedSpeed == nil || sample.power != nil,
                !events.isEmpty, events[eventIndex].date <= sample.date,
                events[eventIndex].state == .running
                    || (events[eventIndex].date == sample.date
                        && events[eventIndex].activeElapsed == sample.activeElapsed),
                sample.activeElapsed >= events[eventIndex].activeElapsed,
                sample.activeElapsed <= events[eventIndex].activeElapsed
                    + sample.date.timeIntervalSince(events[eventIndex].date) + 1,
                eventIndex + 1 == events.count
                    || sample.activeElapsed <= events[eventIndex + 1].activeElapsed,
                previousSample.map({
                    sample.date > $0.date && sample.activeElapsed >= $0.activeElapsed
                        && sample.activeElapsed - $0.activeElapsed <= sample.date.timeIntervalSince($0.date) + 1
                }) ?? true
            else {
                throw RideArchiveError.invalid("Sample values or timeline.")
            }
            if let distance = sample.simulatedDistance,
                let previous = previousDistance, distance < previous
            {
                throw RideArchiveError.invalid("Distance must not decrease.")
            }
            if let distance = sample.simulatedDistance { previousDistance = distance }
            previousSample = sample
        }
        guard endedAt == nil || (samples.last?.activeElapsed ?? 0) <= (events.last?.activeElapsed ?? 0)
        else {
            throw RideArchiveError.invalid("Active duration.")
        }
    }
}

/// Atomic per-ride checkpoints avoid rewriting completed telemetry during an active ride.
/// A failed load blocks writes so corrupted data cannot be silently replaced.
public final class RideArchiveRepository {
    public static let maximumRides = 100
    public static let maximumFileBytes = 128 * 1024 * 1024
    public let directory: URL
    public let fileURL: URL
    public private(set) var rides: [RideArchive] = []
    private var loaded = false
    private var loadFailure: Error?
    private var needsMigration = false
    private struct Checkpoint: Codable {
        let version: Int
        let rides: [RideArchive]
    }
    private struct Index: Codable {
        let version: Int
        let rides: [UUID]
    }
    private struct Header: Decodable { let version: Int }

    public init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("ride-history.json")
    }

    public func load() throws {
        if let loadFailure { throw loadFailure }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumFileBytes
                else {
                    throw RideArchiveError.capacity
                }
                let data = try Data(contentsOf: fileURL)
                let version = try JSONDecoder().decode(Header.self, from: data).version
                let recovered: [RideArchive]
                if version == 1 {
                    recovered = try JSONDecoder().decode(Checkpoint.self, from: data).rides
                    needsMigration = true
                } else if version == 2 {
                    let index = try JSONDecoder().decode(Index.self, from: data)
                    guard index.rides.count <= Self.maximumRides, Set(index.rides).count == index.rides.count else {
                        throw RideArchiveError.duplicateIdentity
                    }
                    var totalBytes = data.count
                    recovered = try index.rides.map { id in
                        let url = rideURL(id)
                        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                        totalBytes += (attributes[.size] as? NSNumber)?.intValue ?? Self.maximumFileBytes
                        guard totalBytes <= Self.maximumFileBytes else { throw RideArchiveError.capacity }
                        let ride = try JSONDecoder().decode(RideArchive.self, from: Data(contentsOf: url))
                        guard ride.id == id else { throw RideArchiveError.duplicateIdentity }
                        return ride
                    }
                } else {
                    throw RideArchiveError.invalid("Unsupported history version.")
                }
                guard recovered.count <= Self.maximumRides, Set(recovered.map(\.id)).count == recovered.count else {
                    throw RideArchiveError.duplicateIdentity
                }
                try recovered.forEach { try $0.validate() }
                rides = recovered
            }
            loaded = true
        } catch {
            let failure = RideArchiveError.corrupt(error.localizedDescription)
            loadFailure = failure
            throw failure
        }
    }

    public func save(_ ride: RideArchive) throws {
        try ride.validate()
        var next = rides
        if let index = next.firstIndex(where: { $0.id == ride.id }) {
            let old = next[index]
            guard old.startedAt == ride.startedAt, old.workout == ride.workout, old.ftp == ride.ftp,
                old.simulation == ride.simulation, old.trainer == ride.trainer,
                old.recordingMode == ride.recordingMode,
                old.cadenceConfiguration == ride.cadenceConfiguration,
                old.initialIntensity == ride.initialIntensity,
                ride.events.starts(with: old.events), ride.samples.starts(with: old.samples),
                old.endedAt == nil || old.endedAt == ride.endedAt,
                old.healthReceipt.status != .saved
                    || (ride.healthReceipt.status == .saved && old.healthReceipt.workoutID == ride.healthReceipt.workoutID)
            else { throw RideArchiveError.duplicateIdentity }
            next[index] = ride
        } else {
            guard next.count < Self.maximumRides else { throw RideArchiveError.capacity }
            next.append(ride)
        }
        try persist(next, changed: ride)
    }

    public func delete(id: UUID) throws {
        try persist(rides.filter { $0.id != id }, changed: nil)
        let url = rideURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch {
                throw RideArchiveError.persistence("History removed, but private telemetry cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    private func rideURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("Rides", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ next: [RideArchive], changed: RideArchive?) throws {
        if let loadFailure { throw loadFailure }
        guard loaded else { throw RideArchiveError.persistence("Load history before saving.") }
        do {
            let index = try JSONEncoder().encode(Index(version: 2, rides: next.map(\.id)))
            let updating = needsMigration ? next : changed.map { [$0] } ?? []
            let payloads = try updating.map { ($0.id, try JSONEncoder().encode($0)) }
            var totalBytes = index.count + payloads.reduce(0) { $0 + $1.1.count }
            let updatedIDs = Set(updating.map(\.id))
            for ride in next where !updatedIDs.contains(ride.id) {
                let attributes = try FileManager.default.attributesOfItem(atPath: rideURL(ride.id).path)
                totalBytes += (attributes[.size] as? NSNumber)?.intValue ?? Self.maximumFileBytes
            }
            guard totalBytes <= Self.maximumFileBytes else { throw RideArchiveError.capacity }
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Rides"), withIntermediateDirectories: true)
            for (id, data) in payloads { try write(data, to: rideURL(id)) }
            if needsMigration || next.map(\.id) != rides.map(\.id) || !FileManager.default.fileExists(atPath: fileURL.path) {
                try write(index, to: fileURL)
            }
            rides = next
            needsMigration = false
        } catch { throw RideArchiveError.persistence(error.localizedDescription) }
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(watchOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: url, options: .atomic)
        #endif
    }
}
