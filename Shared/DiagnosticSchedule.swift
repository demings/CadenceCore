import Foundation

public enum DiagnosticSchedule {
    public static let duration: TimeInterval = 1200

    public static func target(at elapsed: TimeInterval) -> Int? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        switch elapsed {
        case ..<300: return 80
        case ..<600: return 100
        case ..<900:
            return 100 + Int((elapsed - 600) / 300 * 20)
        default: return 80
        }
    }
}
