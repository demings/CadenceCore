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
    case ready, heartbeat, pause, resume, finish, heartRate, snapshot, saved, failure
}

public struct RideDescriptor: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let duration: Double
    public let ftp: Double
    public let simulation: SimulationConfiguration?

    public init(id: UUID, name: String, duration: Double, ftp: Double, simulation: SimulationConfiguration? = nil) {
        self.id = id
        self.name = name
        self.duration = duration
        self.ftp = ftp
        self.simulation = simulation
    }

    public var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 4096 && duration.isFinite &&
        duration > 0 && duration <= 21600 && ftp.isFinite && (1...2000).contains(ftp) &&
        (simulation.map(\.isValid) ?? true)
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

    public init(sequence: Int, state: String, elapsed: Double, interval: Int?, remaining: Double?,
                target: Int?, power: Int?, cadence: Double?, telemetryDate: Date?, status: String,
                simulation: SimulatedMetrics? = nil) {
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
        (simulation.map(\.isValid) ?? true)
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

    public init(rideID: UUID?, action: RideAction, date: Date = Date(), commandID: UUID = UUID(),
                bpm: Double? = nil, snapshot: RideSnapshot? = nil, detail: String? = nil) {
        version = 1
        self.rideID = rideID
        self.commandID = commandID
        self.action = action
        self.date = date
        self.bpm = bpm
        self.snapshot = snapshot
        self.detail = detail
    }

    public static func decode(_ data: Data, now: Date = Date(), allowDelayedReceipt: Bool = false) throws -> RideMessage {
        guard data.count <= 32768 else { throw RideLinkError.invalidMessage }
        let message = try JSONDecoder().decode(Self.self, from: data)
        let age = message.date.timeIntervalSince(now)
        let receipt = allowDelayedReceipt && [.saved, .failure].contains(message.action)
        guard message.version == 1, age <= 5, (age >= -10 || receipt),
              message.action == .heartRate || message.rideID != nil,
              message.snapshot.map(\.isValid) ?? true,
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
              date >= collectionStart, (-3...1).contains(date.timeIntervalSince(now)),
              lastDate.map({ date > $0 }) ?? true else {
            if snapshot.state != "running" { lastDate = nil }
            return nil
        }
        defer { lastDate = date }
        guard let lastDate, date.timeIntervalSince(lastDate) <= 3 else { return nil }
        return DateInterval(start: lastDate, end: date)
    }
}
