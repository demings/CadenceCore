import Foundation

public enum CadenceGuidanceError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration

    public var errorDescription: String? {
        "Cadence ranges must be finite, positive, ordered and at most 250 rpm."
    }
}

public struct CadenceRange: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    public var isValid: Bool {
        lower.isFinite && upper.isFinite && lower > 0 && upper <= 250 && lower < upper
    }
}

/// Advisory policy only. Targets never affect ERG power.
public struct CadenceConfiguration: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let hapticsEnabled: Bool
    public let easy: CadenceRange
    public let moderate: CadenceRange
    public let hard: CadenceRange

    public static let defaults = CadenceConfiguration()

    public init(enabled: Bool = true, hapticsEnabled: Bool = false,
                easy: CadenceRange = .init(lower: 75, upper: 90),
                moderate: CadenceRange = .init(lower: 80, upper: 95),
                hard: CadenceRange = .init(lower: 85, upper: 100)) {
        self.enabled = enabled
        self.hapticsEnabled = hapticsEnabled
        self.easy = easy
        self.moderate = moderate
        self.hard = hard
    }

    public var isValid: Bool { easy.isValid && moderate.isValid && hard.isValid }

    private enum CodingKeys: String, CodingKey { case enabled, hapticsEnabled, easy, moderate, hard }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try values.decode(Bool.self, forKey: .enabled),
                  hapticsEnabled: try values.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? false,
                  easy: try values.decode(CadenceRange.self, forKey: .easy),
                  moderate: try values.decode(CadenceRange.self, forKey: .moderate),
                  hard: try values.decode(CadenceRange.self, forKey: .hard))
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .easy, in: values,
                debugDescription: "Cadence ranges must be finite, positive, ordered and at most 250 rpm.")
        }
    }
}

public struct CadenceGuidanceEvaluator: Sendable {
    public enum Source: String, Codable, Sendable { case workoutTarget, suggestedForIntensity }
    public enum Status: String, Codable, Sendable {
        case unavailable, grace, increaseCadence, withinRange, easeCadence
    }
    public struct Target: Codable, Equatable, Sendable {
        public let range: CadenceRange
        public let source: Source
        public let explicitRPM: Double?

        public init(range: CadenceRange, source: Source, explicitRPM: Double? = nil) {
            self.range = range
            self.source = source
            self.explicitRPM = explicitRPM
        }

        public var isValid: Bool {
            guard range.isValid else { return false }
            switch source {
            case .suggestedForIntensity: return explicitRPM == nil
            case .workoutTarget:
                guard let explicitRPM, explicitRPM.isFinite, (1...250).contains(explicitRPM) else { return false }
                return range.lower == max(1, explicitRPM - 5) && range.upper == min(250, explicitRPM + 5)
            }
        }
    }
    public struct Result: Codable, Equatable, Sendable {
        public let target: Target?
        public let smoothedCadence: Double?
        public let status: Status
        public let recommendsHaptic: Bool

        public init(target: Target?, smoothedCadence: Double?, status: Status, recommendsHaptic: Bool = false) {
            self.target = target
            self.smoothedCadence = smoothedCadence
            self.status = status
            self.recommendsHaptic = recommendsHaptic
        }

        public var isValid: Bool {
            if status == .unavailable {
                return target == nil && smoothedCadence == nil && !recommendsHaptic
            }
            guard let target, target.isValid, let smoothedCadence,
                  smoothedCadence.isFinite, smoothedCadence > 0, smoothedCadence <= 250 else { return false }
            switch status {
            case .withinRange:
                guard (target.range.lower...target.range.upper).contains(smoothedCadence) else { return false }
            case .increaseCadence:
                guard smoothedCadence < min(target.range.upper, target.range.lower + 2) else { return false }
            case .easeCadence:
                guard smoothedCadence > max(target.range.lower, target.range.upper - 2) else { return false }
            case .grace, .unavailable: break
            }
            return !recommendsHaptic || status == .increaseCadence || status == .easeCadence
        }

        private enum CodingKeys: String, CodingKey { case target, smoothedCadence, status, recommendsHaptic }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(target: try values.decodeIfPresent(Target.self, forKey: .target),
                      smoothedCadence: try values.decodeIfPresent(Double.self, forKey: .smoothedCadence),
                      status: try values.decode(Status.self, forKey: .status),
                      recommendsHaptic: try values.decode(Bool.self, forKey: .recommendsHaptic))
            guard isValid else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: values,
                    debugDescription: "Invalid mirrored cadence target, measurement or feedback status.")
            }
        }
    }

    public let configuration: CadenceConfiguration
    private var samples: [(time: Double, rpm: Double)] = []
    private var lastNow: Double?
    private var lastSampleTime: Double?
    private var interval: Int?
    private var target: Target?
    private var pendingBand: Int?
    private var pendingSince: Double?
    private var band: Int?
    private var graceUntil: Double?
    private var deviationSince: Double?
    private var status: Status = .withinRange
    private var lastHaptic: Double?

    public init(configuration: CadenceConfiguration = .defaults) throws {
        guard configuration.isValid else {
            throw CadenceGuidanceError.invalidConfiguration
        }
        self.configuration = configuration
    }

    /// `now` and `sampleTimestamp` use the same monotonic seconds clock.
    /// Feed the commanded target / ride FTP snapshot, never measured power.
    public mutating func evaluate(now: Double, active: Bool, connected: Bool = true,
                                  intervalIndex: Int, targetWatts: Double, ftp: Double,
                                  explicitCadence: Double? = nil, cadence: Double?,
                                  sampleTimestamp: Double?) -> Result {
        guard now.isFinite, lastNow.map({ now >= $0 }) ?? true else {
            resetTracking()
            return unavailable()
        }
        let serviceGap = lastNow.map { now - $0 > 3 } ?? false
        lastNow = now
        guard configuration.enabled, active, connected,
              ftp.isFinite, ftp > 0, targetWatts.isFinite, targetWatts >= 0,
              explicitCadence.map({ $0.isFinite && (1...250).contains($0) }) ?? true,
              let cadence, cadence.isFinite, cadence > 0, cadence <= 250,
              let sampleTimestamp, sampleTimestamp.isFinite,
              sampleTimestamp <= now, now - sampleTimestamp <= 3,
              lastSampleTime.map({ sampleTimestamp >= $0 }) ?? true else {
            resetTracking()
            return unavailable()
        }
        if serviceGap || lastSampleTime.map({ sampleTimestamp - $0 > 3 }) ?? false {
            resetTracking()
        }
        let nextTarget: Target
        if let explicitCadence {
            nextTarget = Target(range: .init(lower: max(1, explicitCadence - 5),
                                            upper: min(250, explicitCadence + 5)),
                                source: .workoutTarget, explicitRPM: explicitCadence)
            band = nil
            pendingBand = nil
        } else {
            let intensity = targetWatts / ftp
            let candidate = intensity <= 0.75 ? 0 : (intensity <= 1 ? 1 : 2)
            if band == nil || interval != intervalIndex { band = candidate }
            // A new ramp band must remain selected for three active seconds.
            if candidate != band {
                if pendingBand != candidate { pendingBand = candidate; pendingSince = now }
                if now - (pendingSince ?? now) >= 3 { band = candidate; pendingBand = nil }
            } else {
                pendingBand = nil
                pendingSince = nil
            }
            let range = band == 0 ? configuration.easy : (band == 1 ? configuration.moderate : configuration.hard)
            nextTarget = Target(range: range, source: .suggestedForIntensity, explicitRPM: nil)
        }
        if interval != intervalIndex || target != nextTarget || graceUntil == nil {
            samples.removeAll()
            status = .withinRange
            deviationSince = nil
            graceUntil = now + 10
        }
        interval = intervalIndex
        target = nextTarget
        if lastSampleTime != sampleTimestamp || samples.isEmpty {
            samples.append((sampleTimestamp, cadence))
        }
        lastSampleTime = sampleTimestamp
        while samples.count > 1 && samples[1].time <= now - 3 { samples.removeFirst() }
        let smoothed = smoothedRPM(now: now)
        guard now >= (graceUntil ?? now) else {
            return Result(target: target, smoothedCadence: smoothed, status: .grace, recommendsHaptic: false)
        }
        let range = nextTarget.range
        let previous = status
        switch status {
        case .increaseCadence:
            if smoothed > range.upper { status = .easeCadence }
            else if smoothed >= min(range.upper, range.lower + 2) { status = .withinRange }
        case .easeCadence:
            if smoothed < range.lower { status = .increaseCadence }
            else if smoothed <= max(range.lower, range.upper - 2) { status = .withinRange }
        default:
            status = smoothed < range.lower ? .increaseCadence : (smoothed > range.upper ? .easeCadence : .withinRange)
        }
        if status == .withinRange { deviationSince = nil }
        else if deviationSince == nil || status != previous { deviationSince = now }
        let haptic = configuration.hapticsEnabled && deviationSince.map({ now - $0 >= 10 }) == true
            && (lastHaptic.map({ now - $0 >= 30 }) ?? true)
        if haptic { lastHaptic = now }
        return Result(target: target, smoothedCadence: smoothed, status: status, recommendsHaptic: haptic)
    }

    private func smoothedRPM(now: Double) -> Double {
        guard let first = samples.first else { return 0 }
        let start = max(now - 3, first.time)
        var weighted = 0.0
        for index in samples.indices {
            let end = index + 1 < samples.count ? samples[index + 1].time : now
            weighted += samples[index].rpm * max(0, end - max(start, samples[index].time))
        }
        return now > start ? weighted / (now - start) : samples.last!.rpm
    }

    private mutating func resetTracking() {
        samples.removeAll()
        lastSampleTime = nil
        graceUntil = nil
        deviationSince = nil
        pendingBand = nil
        pendingSince = nil
        band = nil
        status = .withinRange
    }

    private func unavailable() -> Result {
        Result(target: nil, smoothedCadence: nil, status: .unavailable, recommendsHaptic: false)
    }
}
