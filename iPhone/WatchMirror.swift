import HealthKit
import Observation

@MainActor @Observable
final class WatchMirror: NSObject, HKWorkoutSessionDelegate {
    var heartRate: Double?
    var receivedAt: Date?
    var status = "Start a diagnostic from the CadenceCore Watch app."
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?

    func prepare() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "HealthKit is unavailable."
            return
        }
        do {
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate)]
            )
            store.workoutSessionMirroringStartHandler = { [weak self] session in
                Task { @MainActor in
                    self?.session = session
                    session.delegate = self
                    self?.status = "Watch diagnostic connected."
                }
            }
            status = "Ready for Watch diagnostic. Health read permission is private; missing HR is not zero."
        } catch {
            status = "Health setup failed: \(error.localizedDescription)"
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            status = "Watch session state: \(toState.rawValue)"
            if toState == .ended {
                heartRate = nil
                receivedAt = nil
                session = nil
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            status = "Watch session failed: \(error.localizedDescription)"
            heartRate = nil
            receivedAt = nil
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            for packet in data {
                do {
                    let metric = try JSONDecoder().decode(HeartRateMessage.self, from: packet)
                    guard metric.version == 1, metric.bpm.isFinite, metric.bpm > 0,
                          metric.date.timeIntervalSinceNow <= 5 else {
                        status = "Invalid Watch metric."
                        continue
                    }
                    heartRate = metric.bpm
                    receivedAt = metric.date
                } catch {
                    status = "Invalid Watch message: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct HeartRateMessage: Codable {
    let version: Int
    let bpm: Double
    let date: Date
}
