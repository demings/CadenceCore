import Foundation

public struct SimulationConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public var riderMass: Double
    public var bikeMass: Double
    public var dragArea: Double
    public var rollingResistance: Double
    public var airDensity: Double
    public var efficiency: Double
    public var saveToHealth: Bool

    public init(riderMass: Double, bikeMass: Double = 10, dragArea: Double = 0.32,
                rollingResistance: Double = 0.005, airDensity: Double = 1.225,
                efficiency: Double = 0.97, saveToHealth: Bool = true) {
        version = 1
        self.riderMass = riderMass
        self.bikeMass = bikeMass
        self.dragArea = dragArea
        self.rollingResistance = rollingResistance
        self.airDensity = airDensity
        self.efficiency = efficiency
        self.saveToHealth = saveToHealth
    }

    public var isValid: Bool {
        version == 1 && riderMass.isFinite && (20...300).contains(riderMass) &&
        bikeMass.isFinite && (1...50).contains(bikeMass) &&
        dragArea.isFinite && (0.1...1).contains(dragArea) &&
        rollingResistance.isFinite && (0.001...0.03).contains(rollingResistance) &&
        airDensity.isFinite && (0.5...2).contains(airDensity) &&
        efficiency.isFinite && (0.5...1).contains(efficiency)
    }

    public func speed(watts: Double) throws -> Double {
        guard isValid, watts.isFinite, watts <= 32767 else { throw SimulationError.invalidValues }
        guard watts > 0 else { return 0 }
        let wheelPower = watts * efficiency
        let rollingForce = (riderMass + bikeMass) * 9.80665 * rollingResistance
        let drag = 0.5 * airDensity * dragArea
        var low = 0.0
        var high = 200.0
        for _ in 0..<60 {
            let speed = (low + high) / 2
            if rollingForce * speed + drag * speed * speed * speed < wheelPower {
                low = speed
            } else {
                high = speed
            }
        }
        return (low + high) / 2
    }
}

public enum SimulationError: Error, LocalizedError {
    case invalidValues
    public var errorDescription: String? { "Invalid simulation values. Review the model settings and telemetry." }
}

public struct SimulatedMetrics: Codable, Sendable {
    public let speed: Double?
    public let distance: Double
    public let date: Date?

    public init(speed: Double?, distance: Double, date: Date?) {
        self.speed = speed
        self.distance = distance
        self.date = date
    }

    public var isValid: Bool {
        distance.isFinite && (0...4_320_000).contains(distance) &&
        (speed.map { $0.isFinite && (0...200).contains($0) } ?? true) &&
        (speed == nil || date != nil)
    }
}

public struct RideSimulation: Sendable {
    public let configuration: SimulationConfiguration
    public private(set) var metrics = SimulatedMetrics(speed: nil, distance: 0, date: nil)
    private var previousTime: Double?
    private var previousActiveTime: Double?
    private var previousSpeed: Double?
    private var lastSeenTime: Double?
    private var lastActiveTime: Double?

    public init(configuration: SimulationConfiguration) throws {
        guard configuration.isValid else { throw SimulationError.invalidValues }
        self.configuration = configuration
    }

    public mutating func suspend() {
        previousTime = nil
        previousActiveTime = nil
        previousSpeed = nil
        metrics = SimulatedMetrics(speed: nil, distance: metrics.distance, date: nil)
    }

    public mutating func sample(watts: Int?, uptime: Double, activeTime: Double, date: Date) throws {
        guard uptime.isFinite, activeTime.isFinite, (0...21600).contains(activeTime),
              date.timeIntervalSince1970.isFinite else {
            suspend()
            throw SimulationError.invalidValues
        }
        if let lastSeenTime, uptime <= lastSeenTime { return }
        guard lastActiveTime.map({ activeTime >= $0 }) ?? true,
              watts.map({ (-32768...32767).contains($0) }) ?? true else {
            suspend()
            throw SimulationError.invalidValues
        }
        lastSeenTime = uptime
        lastActiveTime = activeTime
        guard let watts else { suspend(); return }
        let speed = try configuration.speed(watts: Double(watts))
        var distance = metrics.distance
        if let previousTime, let previousActiveTime, let previousSpeed {
            let delta = uptime - previousTime
            let activeDelta = activeTime - previousActiveTime
            // Clip the final sample at the workout's active-time boundary; never bridge long gaps.
            if delta <= 3, activeDelta > 0, activeDelta <= delta + 0.001 {
                distance += (previousSpeed + speed) / 2 * min(delta, activeDelta)
            }
        }
        previousTime = uptime
        previousActiveTime = activeTime
        previousSpeed = speed
        metrics = SimulatedMetrics(speed: speed, distance: distance, date: date)
    }
}
