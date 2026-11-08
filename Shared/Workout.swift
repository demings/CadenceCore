import Foundation
import SwiftData

@Model
public final class SavedWorkout {
    public var name: String
    public var createdAt: Date
    public var favorite: Bool
    public var encodedWorkout: Data
    public var source: Data?

    public init(workout: Workout, source: Data?) throws {
        name = workout.name
        createdAt = Date()
        favorite = false
        encodedWorkout = try JSONEncoder().encode(workout)
        self.source = source
    }
}

public struct WorkoutInterval: Codable, Equatable, Sendable {
    public let duration: Double
    public let startPower: Double
    public let endPower: Double
    public let cadence: Double?

    public init(duration: Double, startPower: Double, endPower: Double, cadence: Double? = nil) {
        self.duration = duration
        self.startPower = startPower
        self.endPower = endPower
        self.cadence = cadence
    }

    public func watts(at elapsed: Double, ftp: Double) -> Double {
        let progress = min(1, max(0, elapsed / duration))
        return (startPower + (endPower - startPower) * progress) * ftp
    }
}

public struct Workout: Codable, Equatable, Sendable {
    public var name: String
    public let description: String
    public let intervals: [WorkoutInterval]
    public let warnings: [String]

    public var duration: Double { intervals.reduce(0) { $0 + $1.duration } }

    public static let sample = Workout(
        name: "Steady Foundation",
        description: "An original example: gradual warm-up, steady riding, and cooldown. Adjust duration and intensity externally through ZWO files.",
        intervals: [
            .init(duration: 300, startPower: 0.4, endPower: 0.6),
            .init(duration: 600, startPower: 0.65, endPower: 0.65),
            .init(duration: 300, startPower: 0.6, endPower: 0.35)
        ],
        warnings: []
    )
}
