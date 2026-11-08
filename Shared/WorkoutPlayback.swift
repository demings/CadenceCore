import Foundation

public enum TrainerReadiness {
    public enum Issue: String, Sendable {
        case disconnected = "Connect your trainer"
        case capabilities = "Waiting for verified ERG capabilities"
        case control = "Trainer control is not granted"
        case busy = "Waiting for trainer acknowledgment"
        case telemetry = "Pedal briefly for fresh trainer measurements"
    }

    public static func issue(connected: Bool, capabilitiesReady: Bool, hasControl: Bool,
                             busy: Bool, sampleDate: Date?, now: Date = Date()) -> Issue? {
        guard connected else { return .disconnected }
        guard capabilitiesReady else { return .capabilities }
        guard hasControl else { return .control }
        guard !busy else { return .busy }
        guard let sampleDate, (0...3).contains(now.timeIntervalSince(sampleDate)) else { return .telemetry }
        return nil
    }
}

public struct WorkoutPlayback: Sendable {
    public enum State: String, Sendable {
        case ready, settingTarget, starting, running, pausing, paused, finishing, completed, interrupted

        public var title: String {
            switch self {
            case .ready: "Ready"
            case .settingTarget: "Setting target"
            case .starting: "Starting"
            case .running: "Running"
            case .pausing: "Pausing"
            case .paused: "Paused"
            case .finishing: "Finishing"
            case .completed: "Completed"
            case .interrupted: "Interrupted"
            }
        }
    }

    public enum Command: Equatable, Sendable {
        case target(Int), start, reducedLoadStop
    }

    public struct Position: Equatable, Sendable {
        public let index: Int
        public let remaining: Double
        public let targetWatts: Int
        public let cadence: Double?
    }

    public let workout: Workout
    public let ftp: Double
    public let range: PowerRange
    public private(set) var state: State = .ready
    public private(set) var elapsed: Double = 0
    public private(set) var error: String?
    public private(set) var intensity: Double = 1
    private var anchor: Double?
    private var lastService: Double?
    private var lastTarget: Int?

    public init(workout: Workout, ftp: Double, range: PowerRange) throws {
        guard ftp.isFinite, (1...2000).contains(ftp), !workout.intervals.isEmpty,
              workout.intervals.count <= ZWOImporter.maximumIntervals,
              workout.duration.isFinite, workout.duration <= ZWOImporter.maximumDuration,
              range.contains(0) else {
            throw WorkoutImportError.invalid("valid FTP, a bounded nonempty workout, and trainer support for 0 W are required.")
        }
        for interval in workout.intervals {
            guard interval.duration.isFinite, interval.duration >= 0.1,
                  interval.startPower.isFinite, interval.endPower.isFinite,
                  (0...3).contains(interval.startPower), (0...3).contains(interval.endPower),
                  interval.cadence.map({ $0.isFinite && (1...250).contains($0) }) ?? true,
                  interval.startPower * ftp >= Double(range.minimum),
                  interval.endPower * ftp >= Double(range.minimum),
                  interval.startPower * ftp <= Double(range.maximum),
                  interval.endPower * ftp <= Double(range.maximum) else {
                throw WorkoutImportError.invalid("an interval has invalid values or exceeds the trainer's supported power range.")
            }
        }
        self.workout = workout
        self.ftp = ftp
        self.range = range
    }

    public var position: Position? {
        var start = 0.0
        for (index, interval) in workout.intervals.enumerated() {
            if elapsed < start + interval.duration {
                let raw = interval.watts(at: elapsed - start, ftp: ftp) * intensity
                let steps = Int(((raw - Double(range.minimum)) / Double(range.increment)).rounded())
                let maximumSteps = (range.maximum - range.minimum) / range.increment
                let watts = range.minimum + min(maximumSteps, max(0, steps)) * range.increment
                return Position(index: index, remaining: start + interval.duration - elapsed,
                                targetWatts: watts, cadence: interval.cadence)
            }
            start += interval.duration
        }
        return nil
    }

    public mutating func begin() -> Command? {
        guard [.ready, .paused, .interrupted].contains(state), let position else { return nil }
        state = .settingTarget
        error = nil
        lastTarget = position.targetWatts
        return .target(position.targetWatts)
    }

    public mutating func adjustIntensity(_ value: Double, commandPending: Bool) throws -> Command? {
        guard [.running, .paused].contains(state), !commandPending,
              value.isFinite, (0.5...1.5).contains(value),
              workout.intervals.allSatisfy({
                  [$0.startPower, $0.endPower].allSatisfy {
                      $0 * ftp * value >= Double(range.minimum) && $0 * ftp * value <= Double(range.maximum)
                  }
              }) else {
            throw WorkoutImportError.invalid("intensity must be 50–150%, fit the trainer range, and change only during running/paused playback with no pending command.")
        }
        intensity = value
        guard state == .running, let position, position.targetWatts != lastTarget else { return nil }
        lastTarget = position.targetWatts
        return .target(position.targetWatts)
    }

    public init(recovering workout: Workout, ftp: Double, range: PowerRange,
                elapsed: Double, intensity: Double = 1) throws {
        try self.init(workout: workout, ftp: ftp, range: range)
        guard elapsed.isFinite, (0..<workout.duration).contains(elapsed),
              intensity.isFinite, (0.5...1.5).contains(intensity),
              workout.intervals.allSatisfy({
                  [$0.startPower, $0.endPower].allSatisfy {
                      $0 * ftp * intensity >= Double(range.minimum) &&
                          $0 * ftp * intensity <= Double(range.maximum)
                  }
              }) else { throw WorkoutImportError.invalid("invalid interrupted ride checkpoint.") }
        self.elapsed = elapsed
        self.intensity = intensity
        state = .interrupted
        error = "Recovered checkpoint. Trainer state is unconfirmed; resume explicitly."
    }

    public mutating func acknowledged(opcode: UInt8, now: Double) -> Command? {
        if state == .settingTarget, opcode == 5 {
            state = .starting
            return .start
        }
        if state == .starting, opcode == 7 {
            state = .running
            anchor = now - elapsed
            lastService = now
        }
        return nil
    }

    public mutating func service(now: Double, commandPending: Bool = false) -> Command? {
        guard state == .running, let anchor, let lastService else { return nil }
        guard now.isFinite, now >= lastService, now - lastService <= 3 else {
            interrupt("Trainer telemetry was interrupted. Workout timing is frozen; resume explicitly after reconnecting.")
            return .reducedLoadStop
        }
        self.lastService = now
        elapsed = min(workout.duration, max(elapsed, now - anchor))
        guard let position else {
            state = .finishing
            self.anchor = nil
            return .reducedLoadStop
        }
        guard !commandPending, position.targetWatts != lastTarget else { return nil }
        lastTarget = position.targetWatts
        return .target(position.targetWatts)
    }

    public mutating func pause(now: Double) -> Command? {
        guard state == .running else { return nil }
        if let anchor, let lastService, now.isFinite, now >= lastService, now - lastService <= 3 {
            elapsed = min(workout.duration, max(elapsed, now - anchor))
        }
        state = elapsed >= workout.duration ? .finishing : .pausing
        anchor = nil
        return .reducedLoadStop
    }

    public mutating func finish(now: Double? = nil) -> Command? {
        guard ![.completed, .finishing].contains(state) else { return nil }
        if state == .running, let now, let anchor, let lastService,
           now.isFinite, now >= lastService, now - lastService <= 3 {
            elapsed = min(workout.duration, max(elapsed, now - anchor))
        }
        state = .finishing
        anchor = nil
        return .reducedLoadStop
    }

    public mutating func stopped() {
        switch state {
        case .pausing: state = .paused
        case .finishing: state = .completed
        default: break
        }
    }

    public mutating func interrupt(_ reason: String) {
        guard state != .completed else { return }
        state = .interrupted
        anchor = nil
        error = reason
    }
}
