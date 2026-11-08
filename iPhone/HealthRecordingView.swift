import HealthKit
import SwiftUI

private enum RecordedQuantity: String, CaseIterable {
    case heartRate, activeEnergy, restingEnergy, power, cadence, speed, distance

    var type: HKQuantityType {
        switch self {
        case .heartRate: HKQuantityType(.heartRate)
        case .activeEnergy: HKQuantityType(.activeEnergyBurned)
        case .restingEnergy: HKQuantityType(.basalEnergyBurned)
        case .power: HKQuantityType(.cyclingPower)
        case .cadence: HKQuantityType(.cyclingCadence)
        case .speed: HKQuantityType(.cyclingSpeed)
        case .distance: HKQuantityType(.distanceCycling)
        }
    }

    var label: String {
        switch self {
        case .heartRate: "Heart rate (bpm)"
        case .activeEnergy: "Active energy (kcal)"
        case .restingEnergy: "Resting energy (kcal)"
        case .power: "Measured cycling power (W)"
        case .cadence: "Measured cycling cadence (rpm)"
        case .speed: "Cycling speed (km/h)"
        case .distance: "Cycling distance (m)"
        }
    }

    var unit: HKUnit {
        switch self {
        case .heartRate, .cadence: HKUnit.count().unitDivided(by: .minute())
        case .activeEnergy, .restingEnergy: .kilocalorie()
        case .power: .watt()
        case .speed: .meter().unitDivided(by: .second())
        case .distance: .meter()
        }
    }

    var cumulative: Bool { [.activeEnergy, .restingEnergy, .distance].contains(self) }
}

struct HealthRecordingView: View {
    @State private var workouts: [HKWorkout] = []
    @State private var selectedID: UUID?
    @State private var referenceID: UUID?
    @State private var report: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var store = HKHealthStore()
    @State private var operation: Task<Void, Never>?
    @State private var authorization = HealthReadAuthorization()

    var body: some View {
        List {
            Section {
                Text("Check what was actually saved")
                    .font(.headline)
                Text("Compare a saved ride with a native Indoor Cycle reference. This page never changes Health data.")
                    .font(.callout)
                Button(loading ? "Loading…" : "Load recent cycling workouts") {
                    operation = Task { await loadWorkouts() }
                }
                .disabled(loading)
                if loading {
                    Text("Complete the Health permission sheet if shown. If it does not appear, cancel and retry after opening Health.")
                        .font(.caption)
                    Button("Cancel inspection", role: .cancel) {
                        operation?.cancel()
                        authorization.cancel()
                    }
                }
                DisclosureGroup("Permissions and Watch sync") {
                    Text(
                        "Read-only inspection of recent cycling workouts. Select a CadenceCore ride and optionally a reference ride from Apple's Workout app to compare supported saved data."
                    )
                    Text(
                        "Health read denial is private: missing workouts or samples mean no accessible data, not necessarily zero or a failed recording. Watch-to-iPhone Health sync can take time."
                    )
                }.font(.footnote).foregroundStyle(.secondary)
            }
            if loaded, workouts.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label {
                            Text("No accessible cycling workouts")
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "heart.text.clipboard")
                        }
                    } description: {
                        Text(
                            "Allow read access in Health settings, save a ride, wait for Watch sync, then reload. Searches cover the latest 10 cycling workouts in the past 30 days."
                        )
                    }
                }
            }
            if !workouts.isEmpty {
                Section("Comparison") {
                    Picker("Your ride", selection: $selectedID) {
                        Text("Choose a ride").tag(nil as UUID?)
                        ForEach(workouts, id: \.uuid) { workout in
                            Text(title(workout)).tag(Optional(workout.uuid))
                        }
                    }
                    Picker("Reference ride", selection: $referenceID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(workouts.filter { $0.uuid != selectedID }, id: \.uuid) { workout in
                            Text(title(workout)).tag(Optional(workout.uuid))
                        }
                    }
                    Text(
                        "Use a separate native Indoor Cycle workout with similar duration/effort. Differences alone do not establish a bug or identical calorie/ring calculations."
                    )
                    .font(.footnote)
                    Button("Inspect saved data") { operation = Task { await inspect() } }
                        .disabled(loading || selectedID == nil)
                }
            }
            if let error {
                Section("Could not read Health") { Text(error).foregroundStyle(.red) }
            }
            if let report {
                Section("Saved-data report") {
                    Text(report).font(.footnote.monospaced()).textSelection(.enabled)
                    ShareLink(item: report) { Label("Share recording report", systemImage: "square.and.arrow.up") }
                    Text(
                        "Sharing is optional. The report contains workout identifiers, times, source and health summaries. Review it before sharing."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Health recording")
        .onChange(of: selectedID) {
            if selectedID == referenceID { referenceID = nil }
            report = nil
        }
        .onChange(of: referenceID) { report = nil }
        .onDisappear {
            operation?.cancel()
            authorization.cancel()
        }
    }

    private func title(_ workout: HKWorkout) -> String {
        "\(workout.sourceRevision.source.name) · \(workout.startDate.formatted(date: .abbreviated, time: .shortened))"
    }

    @MainActor private func loadWorkouts() async {
        loading = true
        error = nil
        report = nil
        defer { loading = false }
        do {
            guard HKHealthStore.isHealthDataAvailable() else { throw HealthInspectionError.unavailable }
            let read: Set<HKObjectType> = Set(RecordedQuantity.allCases.map(\.type)).union([HKObjectType.workoutType()])
            try await authorization.request(store: store, read: read)
            try Task.checkCancellation()
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForWorkouts(with: .cycling),
                HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-30 * 86400), end: Date()),
            ])
            workouts = try await HKSampleQueryDescriptor(
                predicates: [.workout(predicate)],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 10
            ).result(for: store)
            selectedID =
                workouts.first(where: {
                    $0.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier || $0.metadata?["CadenceCoreFTP"] != nil
                })?.uuid
            referenceID = nil
            loaded = true
        } catch {
            self.error =
                "\(error.localizedDescription) [\((error as NSError).domain):\((error as NSError).code)]. Review Health read permissions and retry."
        }
    }

    @MainActor private func inspect() async {
        guard let workout = workouts.first(where: { $0.uuid == selectedID }) else { return }
        loading = true
        error = nil
        report = nil
        defer { loading = false }
        do {
            var text = "CadenceCore saved-recording inspection\nNo GPS/native-source spoofing or Health changes.\n\n"
            text += try await describe(workout)
            if let reference = workouts.first(where: { $0.uuid == referenceID }) {
                text += "\n\nREFERENCE WORKOUT\n" + (try await describe(reference))
            }
            text +=
                "\n\nAccessible samples only; missing data may reflect permission or sync. Coverage is the union of sample timestamp intervals, not proof of continuous sensor quality. Sample queries are capped at 10,000 per metric. Activity rings, native zones and proprietary Fitness presentation must be checked separately in Fitness."
            report = text
        } catch {
            self.error =
                "Inspection failed: \(error.localizedDescription) [\((error as NSError).domain):\((error as NSError).code)]. No complete report generated; retry after Health sync."
        }
    }

    @MainActor private func describe(_ workout: HKWorkout) async throws -> String {
        let metadata = workout.metadata ?? [:]
        let bounds = DateInterval(start: workout.startDate, end: workout.endDate)
        var lines = [
            "Source: \(workout.sourceRevision.source.name) (\(workout.sourceRevision.source.bundleIdentifier))",
            "Workout: \(workout.uuid.uuidString)",
            "Indoor metadata: \((metadata[HKMetadataKeyIndoorWorkout] as? Bool).map { $0 ? "yes" : "no" } ?? "not available")",
            "Start: \(workout.startDate.ISO8601Format())",
            "End: \(workout.endDate.ISO8601Format())",
            "Health active duration: \(number(workout.duration)) s",
            "Elapsed span: \(number(bounds.duration)) s",
            "Pause events: \((workout.workoutEvents ?? []).filter { $0.type == .pause }.count)",
            "Resume events: \((workout.workoutEvents ?? []).filter { $0.type == .resume }.count)",
        ]
        if let expected = metadata["CadenceCoreActiveDurationSeconds"] as? Double {
            lines.append(
                "iPhone active duration: \(number(expected)) s; Health difference: \(number(workout.duration - expected)) s (mirroring/lifecycle latency may differ)"
            )
        }
        if let enabled = metadata["CadenceCoreSimulationHealthEnabled"] as? Bool {
            lines.append("Simulated Health travel requested: \(enabled ? "yes" : "no")")
        }
        if let confirmed = metadata["CadenceCoreTrainerStopConfirmed"] as? Bool {
            lines.append("Trainer finish confirmed: \(confirmed ? "yes" : "NO")")
        }
        if let warning = metadata["CadenceCoreRecordingWarning"] as? String { lines.append("Recording warning: \(warning)") }
        for metric in RecordedQuantity.allCases {
            try Task.checkCancellation()
            let samples = try await HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: metric.type, predicate: HKQuery.predicateForObjects(from: workout))],
                sortDescriptors: [SortDescriptor(\.startDate)], limit: 10001
            ).result(for: store)
            let visible = Array(samples.prefix(10000))
            let coverage = RecordingCoverage.seconds(visible.map { DateInterval(start: $0.startDate, end: $0.endDate) }, within: bounds)
            let statistics = workout.statistics(for: metric.type)
            let value = metric.cumulative ? statistics?.sumQuantity() : statistics?.averageQuantity()
            let scale = metric == .speed ? 3.6 : 1
            let summary = value.map { number($0.doubleValue(for: metric.unit) * scale) } ?? "not accessible"
            let simulated = visible.filter { $0.metadata?["CadenceCoreSimulated"] as? Bool == true }.count
            lines.append("\n\(metric.label): \(metric.cumulative ? "sum" : "average") \(summary)")
            lines.append(
                "Accessible samples: \(visible.count)\(samples.count > 10000 ? "+" : ""); timestamp coverage: \(number(coverage)) s; labeled simulated: \(simulated)"
            )
            if metric == .heartRate, let maximum = statistics?.maximumQuantity() {
                lines.append("Maximum HR: \(number(maximum.doubleValue(for: metric.unit))) bpm")
            }
            if metric == .distance, let expected = metadata["CadenceCoreExpectedDistanceMeters"] as? Double {
                lines.append("Expected simulated total: \(number(expected)) m")
                if let value {
                    let difference = value.doubleValue(for: .meter()) - expected
                    lines.append("Saved minus expected: \(number(difference)) m; within 1 m: \(abs(difference) <= 1 ? "yes" : "NO")")
                } else {
                    lines.append("Distance comparison unavailable; no accessible saved aggregate.")
                }
            }
        }
        let active = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let resting = workout.statistics(for: HKQuantityType(.basalEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        if let active, let resting {
            lines.append("\nTotal energy (active + resting): \(number(active + resting)) kcal")
        } else {
            lines.append("\nTotal energy unavailable: active and resting quantities are both required; no fabricated fallback.")
        }
        return lines.joined(separator: "\n")
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

@MainActor @Observable
private final class HealthReadAuthorization {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var requestID: UUID?

    func request(store: HKHealthStore, read: Set<HKObjectType>) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            requestID = id
            self.continuation = continuation
            timeout = Task {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                finish(.failure(HealthInspectionError.authorizationTimeout), id: id)
            }
            store.requestAuthorization(toShare: [], read: read) { success, error in
                Task { @MainActor in
                    if let error {
                        self.finish(.failure(error), id: id)
                    } else if success {
                        self.finish(.success(()), id: id)
                    } else {
                        self.finish(.failure(HealthInspectionError.authorizationIncomplete), id: id)
                    }
                }
            }
        }
    }

    func cancel() { if let id = requestID { finish(.failure(CancellationError()), id: id) } }

    private func finish(_ result: Result<Void, Error>, id: UUID) {
        guard requestID == id, let continuation else { return }
        self.continuation = nil
        requestID = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}

private enum HealthInspectionError: LocalizedError {
    case unavailable, authorizationTimeout, authorizationIncomplete
    var errorDescription: String? {
        switch self {
        case .unavailable: "HealthKit is unavailable on this device."
        case .authorizationTimeout: "Health permission request did not complete within 60 seconds. Open Health and retry."
        case .authorizationIncomplete: "Health permission request was not completed. Retry from this screen."
        }
    }
}
