import Foundation

public enum DiagnosticSchedule {
    public enum Length: Int, CaseIterable, Sendable {
        case short = 4
        case extended = 20

        public var duration: TimeInterval { TimeInterval(rawValue * 60) }
        public var stageDuration: TimeInterval { duration / 4 }
    }

    public static func target(at elapsed: TimeInterval, length: Length = .extended) -> Int? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < length.duration else { return nil }
        let stage = length.stageDuration
        switch elapsed {
        case ..<stage: return 80
        case ..<(2 * stage): return 100
        case ..<(3 * stage):
            return 100 + Int((elapsed - 2 * stage) / stage * 20)
        default: return 80
        }
    }
}

public struct ReducedLoadStop: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle, waitingForPendingCommand, requestingReducedLoad, requestingStop, completed, failed
    }

    public enum Command: Equatable, Sendable {
        case zeroWatts, stop
    }

    public private(set) var state: State = .idle

    public init() {}

    public var isInProgress: Bool {
        switch state {
        case .waitingForPendingCommand, .requestingReducedLoad, .requestingStop: true
        default: false
        }
    }

    public mutating func begin(commandPending: Bool) -> Command? {
        guard !isInProgress else { return nil }
        state = commandPending ? .waitingForPendingCommand : .requestingReducedLoad
        return commandPending ? nil : .zeroWatts
    }

    public mutating func commandAcknowledged() -> Command? {
        switch state {
        case .waitingForPendingCommand:
            state = .requestingReducedLoad
            return .zeroWatts
        case .requestingReducedLoad:
            state = .requestingStop
            return .stop
        case .requestingStop:
            state = .completed
            return nil
        default:
            return nil
        }
    }

    public mutating func fail() {
        state = .failed
    }
}
