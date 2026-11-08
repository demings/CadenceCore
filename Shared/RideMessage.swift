import Foundation

public enum WatchStartPhase: String, Sendable {
    case authorization = "Health permissions"
    case creating = "Creating Watch session"
    case preparing = "Preparing Watch session"
    case mirroring = "Connecting to iPhone"
    case requesting = "Requesting trainer start"
    case collecting = "Starting Health recording"
    case recording = "Watch Health session"

    public func failure(_ error: Error) -> String {
        let detail = error as NSError
        return "\(rawValue) failed: \(detail.localizedDescription) [\(detail.domain):\(detail.code)]. End any active workout in Apple's Workout or CadenceCore, keep iPhone nearby, and retry. If this persists, share this error detail."
    }
}

public enum RideAction: String, Codable, Sendable {
    case ready, heartbeat, pause, resume, finish, heartRate, snapshot, saved, failure, intensity
}

public struct RecordingMetrics: Codable, Equatable, Sendable {
    public let averageHeartRate: Double?
    public let maximumHeartRate: Double?
    public let activeKilocalories: Double?
    public let restingKilocalories: Double?

    public init(averageHeartRate: Double?, maximumHeartRate: Double?,
                activeKilocalories: Double?, restingKilocalories: Double?) {
        self.averageHeartRate = averageHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.activeKilocalories = activeKilocalories
        self.restingKilocalories = restingKilocalories
    }

    public var totalKilocalories: Double? {
        guard let activeKilocalories, let restingKilocalories else { return nil }
        return activeKilocalories + restingKilocalories
    }

    public var isValid: Bool {
        [averageHeartRate, maximumHeartRate].allSatisfy { $0.map { $0.isFinite && (1...300).contains($0) } ?? true } &&
        [activeKilocalories, restingKilocalories].allSatisfy { $0.map { $0.isFinite && (0...100000).contains($0) } ?? true } &&
        (averageHeartRate.flatMap { average in maximumHeartRate.map { average <= $0 } } ?? true)
    }
}

public enum RecordingCoverage {
    public static func seconds(_ intervals: [DateInterval], within bounds: DateInterval) -> Double {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, bounds.start)
            let end = min(interval.end, bounds.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var total = 0.0
        var end = bounds.start
        for interval in clipped {
            total += max(0, interval.end.timeIntervalSince(max(end, interval.start)))
            end = max(end, interval.end)
        }
        return total
    }
}

public struct RideDescriptor: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let duration: Double
    public let ftp: Double
    public let simulation: SimulationConfiguration?
    public let cadenceConfiguration: CadenceConfiguration?

    public init(id: UUID, name: String, duration: Double, ftp: Double, simulation: SimulationConfiguration? = nil,
                cadenceConfiguration: CadenceConfiguration? = nil) {
        self.id = id
        self.name = name
        self.duration = duration
        self.ftp = ftp
        self.simulation = simulation
        self.cadenceConfiguration = cadenceConfiguration
    }

    public var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 4096 && duration.isFinite &&
        duration > 0 && duration <= 21600 && ftp.isFinite && (1...2000).contains(ftp) &&
        (simulation.map(\.isValid) ?? true) && (cadenceConfiguration.map(\.isValid) ?? true)
    }
}

public struct RideSnapshot: Codable, Sendable {
    public let sequence: Int
    public let state: String
    public let elapsed: Double
    public let interval: Int?
    public let remaining: Double?
    public let target: Int?
    public let power: Int?
    public let cadence: Double?
    public let telemetryDate: Date?
    public let status: String
    public let simulation: SimulatedMetrics?
    public let intensity: Double?
    public let guidance: CadenceGuidanceEvaluator.Result?
    public let cue: String?
    public let acknowledgedCommandID: UUID?

    public init(sequence: Int, state: String, elapsed: Double, interval: Int?, remaining: Double?,
                target: Int?, power: Int?, cadence: Double?, telemetryDate: Date?, status: String,
                simulation: SimulatedMetrics? = nil, intensity: Double? = nil,
                guidance: CadenceGuidanceEvaluator.Result? = nil, cue: String? = nil,
                acknowledgedCommandID: UUID? = nil) {
        self.sequence = sequence
        self.state = state
        self.elapsed = elapsed
        self.interval = interval
        self.remaining = remaining
        self.target = target
        self.power = power
        self.cadence = cadence
        self.telemetryDate = telemetryDate
        self.status = status
        self.simulation = simulation
        self.intensity = intensity
        self.guidance = guidance
        self.cue = cue
        self.acknowledgedCommandID = acknowledgedCommandID
    }

    public var isValid: Bool {
        sequence >= 0 && ["ready", "settingTarget", "starting", "running", "pausing", "paused",
                         "finishing", "completed", "interrupted"].contains(state) &&
        elapsed.isFinite && (0...21600).contains(elapsed) &&
        (remaining.map { $0.isFinite && (0...21600).contains($0) } ?? true) &&
        (interval.map { (1...2000).contains($0) } ?? true) &&
        (target.map { (0...32767).contains($0) } ?? true) &&
        (power.map { (-32768...32767).contains($0) } ?? true) &&
        (cadence.map { $0.isFinite && (0...1000).contains($0) } ?? true) &&
        (simulation.map(\.isValid) ?? true) &&
        (intensity.map { $0.isFinite && (0.5...1.5).contains($0) } ?? true) &&
        (guidance.map(\.isValid) ?? true) && (cue.map { $0.utf8.count <= 8192 } ?? true)
    }
}

public struct RideMessage: Codable, Sendable {
    public let version: Int
    public let rideID: UUID?
    public let commandID: UUID
    public let action: RideAction
    public let date: Date
    public let bpm: Double?
    public let snapshot: RideSnapshot?
    public let detail: String?
    public let recording: RecordingMetrics?
    public let requestedIntensity: Double?
    public let savedWorkoutID: UUID?

    public init(rideID: UUID?, action: RideAction, date: Date = Date(), commandID: UUID = UUID(),
                bpm: Double? = nil, snapshot: RideSnapshot? = nil, detail: String? = nil,
                recording: RecordingMetrics? = nil, requestedIntensity: Double? = nil,
                savedWorkoutID: UUID? = nil) {
        version = 1
        self.rideID = rideID
        self.commandID = commandID
        self.action = action
        self.date = date
        self.bpm = bpm
        self.snapshot = snapshot
        self.detail = detail
        self.recording = recording
        self.requestedIntensity = requestedIntensity
        self.savedWorkoutID = savedWorkoutID
    }

    public static func decode(_ data: Data, now: Date = Date(), allowDelayedReceipt: Bool = false) throws -> RideMessage {
        guard data.count <= 32768 else { throw RideLinkError.invalidMessage }
        let message = try JSONDecoder().decode(Self.self, from: data)
        let age = message.date.timeIntervalSince(now)
        let receipt = allowDelayedReceipt && [.saved, .failure].contains(message.action)
        guard message.version == 1, age <= 5, (age >= -10 || receipt),
              message.action == .heartRate || message.rideID != nil,
              message.snapshot.map(\.isValid) ?? true,
              message.recording.map(\.isValid) ?? true,
              message.requestedIntensity.map({ $0.isFinite && (0.5...1.5).contains($0) }) ?? true,
              message.action != .intensity || message.requestedIntensity != nil,
              message.savedWorkoutID == nil || message.action == .saved,
              message.bpm.map({ $0.isFinite && (1...300).contains($0) }) ?? true,
              message.action != .snapshot || message.snapshot != nil,
              message.action != .heartRate || message.bpm != nil else {
            throw RideLinkError.invalidMessage
        }
        return message
    }
}

public enum RideLinkError: Error, LocalizedError {
    case invalidMessage
    case noSavedWorkout
    public var errorDescription: String? {
        switch self {
        case .invalidMessage: "Invalid or stale workout communication."
        case .noSavedWorkout: "HealthKit finished without returning a saved workout."
        }
    }
}

public struct RideCommandGate: Sendable {
    public let rideID: UUID
    private var commands: Set<UUID> = []
    public init(rideID: UUID) { self.rideID = rideID }

    public mutating func accept(_ message: RideMessage) -> Bool {
        guard message.rideID == rideID, !commands.contains(message.commandID) else { return false }
        commands.insert(message.commandID)
        return true
    }
}

public struct TrainerSampleWindow: Sendable {
    private var lastDate: Date?
    public init() {}

    public mutating func take(_ snapshot: RideSnapshot, now: Date, collectionStart: Date) -> DateInterval? {
        guard snapshot.state == "running", let date = snapshot.telemetryDate,
              date >= collectionStart, (-3...1).contains(date.timeIntervalSince(now)) else {
            lastDate = nil
            return nil
        }
        guard lastDate.map({ date > $0 }) ?? true else { return nil }
        defer { lastDate = date }
        guard let lastDate, date.timeIntervalSince(lastDate) <= 3 else { return nil }
        return DateInterval(start: lastDate, end: date)
    }
}
