import HealthKit
import Observation
import SwiftUI

@main
struct CadenceCoreWatchApp: App {
    @State private var workout = DiagnosticWorkout()

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 12) {
                    Text("CadenceCore").font(.headline)
                    Text("HR diagnostic").font(.caption)
                    Text(workout.status).font(.caption)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let fresh = workout.sampleDate.map { context.date.timeIntervalSince($0) <= 10 } ?? false
                        Text(fresh ? workout.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "Waiting for HR" : "HR unavailable")
                            .font(.title2.monospacedDigit())
                    }
                    if workout.active {
                        Button("End and discard", role: .destructive) { workout.end() }
                    } else {
                        Button("Start diagnostic") { Task { await workout.start() } }
                            .disabled(workout.starting)
                    }
                    Text("No trainer controls yet. This session will not be saved.")
                        .font(.caption2)
                }
                .padding()
            }
            .tint(.teal)
        }
    }
}

@MainActor @Observable
final class DiagnosticWorkout: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    var status = "Enable mirroring on iPhone first."
    var active = false
    var starting = false
    var heartRate: Double?
    var sampleDate: Date?
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    func start() async {
        guard !active, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [HKQuantityType(.heartRate)]
            )
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .cycling
            configuration.locationType = .indoor
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            self.session = session
            self.builder = builder
            session.delegate = self
            builder.delegate = self
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            let start = Date()
            session.startActivity(with: start)
            active = true
            try await builder.beginCollection(at: start)
            try await session.startMirroringToCompanionDevice()
            status = "Measuring HR; mirrored to iPhone."
        } catch {
            status = "Start failed: \(error.localizedDescription)"
            session?.end()
            builder?.discardWorkout()
            active = false
            session = nil
            builder = nil
        }
    }

    func end() {
        session?.end()
        builder?.discardWorkout()
        active = false
        session = nil
        builder = nil
        heartRate = nil
        sampleDate = nil
        status = "Ended. Diagnostic discarded."
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            if toState == .ended {
                builder?.discardWorkout()
                active = false
                heartRate = nil
                sampleDate = nil
                session = nil
                builder = nil
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            end()
            status = "Session failed: \(error.localizedDescription)"
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            guard active, builder === workoutBuilder, collectedTypes.contains(HKQuantityType(.heartRate)),
                  let statistics = workoutBuilder.statistics(for: HKQuantityType(.heartRate)),
                  let quantity = statistics.mostRecentQuantity(),
                  let interval = statistics.mostRecentQuantityDateInterval(),
                  let session else { return }
            let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            heartRate = bpm
            sampleDate = interval.end
            do {
                let message = HeartRateMessage(version: 1, bpm: bpm, date: interval.end)
                try await session.sendToRemoteWorkoutSession(data: JSONEncoder().encode(message))
            } catch {
                status = "HR measured locally; iPhone delivery failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct HeartRateMessage: Codable {
    let version: Int
    let bpm: Double
    let date: Date
}
