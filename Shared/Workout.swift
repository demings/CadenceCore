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

    public var isValid: Bool {
        duration.isFinite && (0.1...ZWOImporter.maximumDuration).contains(duration)
            && startPower.isFinite && endPower.isFinite
            && (0...3).contains(startPower) && (0...3).contains(endPower)
            && (cadence.map { $0.isFinite && (1...250).contains($0) } ?? true)
    }
}

public struct WorkoutTextCue: Codable, Equatable, Sendable {
    /// Absolute active-workout seconds, not elapsed wall-clock time.
    public let offset: Double
    public let message: String
    public let duration: Double

    public init(offset: Double, message: String, duration: Double = 5) {
        self.offset = offset
        self.message = message
        self.duration = duration
    }

    public var isValid: Bool {
        offset.isFinite && offset >= 0 && duration.isFinite && (0.1...60).contains(duration)
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && message.count <= ZWOImporter.maximumCueCharacters
            && !message.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }
}

public struct Workout: Codable, Equatable, Sendable {
    public var name: String
    public let description: String
    public let intervals: [WorkoutInterval]
    public let warnings: [String]
    /// Nil for legacy persisted workouts. Cues in a repeat block occur once at its block-relative offset.
    public let cues: [WorkoutTextCue]?

    public init(name: String, description: String, intervals: [WorkoutInterval],
                warnings: [String], cues: [WorkoutTextCue]? = nil) {
        self.name = name
        self.description = description
        self.intervals = intervals
        self.warnings = warnings
        self.cues = cues
    }

    public var duration: Double { intervals.reduce(0) { $0 + $1.duration } }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !intervals.isEmpty && intervals.count <= ZWOImporter.maximumIntervals
            && intervals.allSatisfy(\.isValid) && duration.isFinite
            && duration <= ZWOImporter.maximumDuration
            && (cues.map { cues in
                cues.count <= ZWOImporter.maximumCues
                    && cues.allSatisfy { $0.isValid && $0.offset < duration }
                    && zip(cues, cues.dropFirst()).allSatisfy { $0.offset <= $1.offset }
            } ?? true)
    }

    private enum CodingKeys: String, CodingKey { case name, description, intervals, warnings, cues }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name),
                  description: try values.decode(String.self, forKey: .description),
                  intervals: try values.decode([WorkoutInterval].self, forKey: .intervals),
                  warnings: try values.decode([String].self, forKey: .warnings),
                  cues: try values.decodeIfPresent([WorkoutTextCue].self, forKey: .cues))
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .intervals, in: values,
                debugDescription: "Invalid bounded workout timeline or text cues.")
        }
    }

    public static let shortCheck = Workout(
        name: "Five-Minute Ride Check",
        description: "An original short ride for checking trainer control, Watch recording, and saving. Choose your own comfortable effort.",
        intervals: [
            .init(duration: 60, startPower: 0.35, endPower: 0.5),
            .init(duration: 180, startPower: 0.5, endPower: 0.5),
            .init(duration: 60, startPower: 0.5, endPower: 0.3)
        ], warnings: [])

    public static let cadencePractice = Workout(
        name: "Cadence Practice",
        description: "Original easy-power cadence blocks. Cadence targets are advisory, not individualized prescriptions; keep a comfortable rhythm.",
        intervals: [
            .init(duration: 300, startPower: 0.35, endPower: 0.55),
            .init(duration: 240, startPower: 0.6, endPower: 0.6, cadence: 80),
            .init(duration: 240, startPower: 0.6, endPower: 0.6, cadence: 90),
            .init(duration: 120, startPower: 0.55, endPower: 0.55, cadence: 80),
            .init(duration: 300, startPower: 0.55, endPower: 0.3)
        ], warnings: [])

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
