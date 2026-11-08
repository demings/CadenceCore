import Charts
import SwiftUI

struct RideView: View {
    @Bindable var trainer: TrainerDiagnostic
    @Bindable var watch: WatchMirror
    @State private var confirmFinish = false
    @State private var confirmRelease = false
    @State private var intensity = 100.0

    var body: some View {
        ScrollView {
            if let playback = trainer.playback {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(playback.state.title, systemImage: stateIcon(playback.state))
                            .font(.subheadline.bold()).foregroundStyle(.teal)
                        Text(playback.workout.name).font(.title2.bold())
                        Text(trainer.playbackStatus).font(.callout).foregroundStyle(.secondary)
                        ProgressView(value: playback.elapsed, total: playback.workout.duration).tint(.teal)
                        HStack {
                            Label(clock(playback.elapsed), systemImage: "timer")
                            Spacer()
                            Text("\(clock(max(0, playback.workout.duration - playback.elapsed))) remaining")
                        }.font(.subheadline.monospacedDigit())
                        if let position = playback.position {
                            Text(
                                "Interval \(position.index + 1) of \(playback.workout.intervals.count) · \(Int(ceil(position.remaining))) sec left"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }.rideCard()
                    liveMetrics(playback)
                    if let guidance = trainer.cadenceGuidance, let target = guidance.target {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(guidanceLabel(guidance.status), systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                            Text(
                                "\(Int(target.range.lower))–\(Int(target.range.upper)) rpm · \(target.source == .workoutTarget ? "Workout target" : "Suggested for intensity")"
                            )
                            Text("Advisory only. ERG power is unchanged.").font(.caption).foregroundStyle(
                                .secondary)
                        }.rideCard()
                    }
                    if let cue = trainer.activeCue {
                        Label(cue, systemImage: "text.bubble.fill").font(.headline).rideCard()
                            .accessibilityLabel("Workout instruction: \(cue)")
                    }
                    profile(playback)
                    if [.paused, .interrupted].contains(playback.state), !trainer.readyToRide {
                        VStack(alignment: .leading, spacing: 12) { TrainerSetupView(trainer: trainer) }
                            .rideCard()
                    }
                    if [.running, .paused].contains(playback.state) {
                        DisclosureGroup("Adjust intensity · \(Int(playback.intensity * 100))%") {
                            VStack(alignment: .leading, spacing: 12) {
                                Slider(value: $intensity, in: 50...150, step: 5)
                                    .accessibilityLabel("Workout intensity percent")
                                Button("Apply \(Int(intensity))% intensity") {
                                    trainer.adjustIntensity(intensity / 100)
                                }
                                .disabled(trainer.pending || trainer.stopFlow.isInProgress)
                                Text(
                                    "Changes ERG targets, not your \(Int(playback.ftp)) W FTP. Trainer limits are checked before applying."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 12)
                        }.rideCard()
                    }
                    recordingSummary
                    if let error = trainer.archiveError ?? trainer.archiveStore.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Local save needs attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                            Text(error).font(.callout)
                            Button("Retry local save") { trainer.saveArchiveNow() }
                        }.rideCard()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            watch.isWatchRide ? "Watch recording" : "iPhone-only ride",
                            systemImage: watch.isWatchRide ? "applewatch" : "iphone"
                        )
                        .font(.headline)
                        Text(watch.isWatchRide ? watch.status : "This ride is not recorded to Health.").font(
                            .callout)
                        if playback.state == .completed, watch.isWatchRide {
                            NavigationLink("Inspect saved Health data") { HealthRecordingView() }
                        }
                        if playback.state == .completed, watch.coordinatedID != nil {
                            Button("Release Watch coordination") { confirmRelease = true }
                        }
                        DisclosureGroup("Trainer safety and connection details") {
                            Text(trainer.stopStatus).font(.caption).padding(.top, 8)
                            Text(
                                "Finish requests 0 W then stop, not zero resistance. Keep both apps running. After a crash or lost link, the trainer may retain its last target; stop pedaling and reconnect explicitly."
                            )
                            .font(.caption)
                        }
                    }.rideCard()
                }.padding()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Ride")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { controls }
        .onAppear { intensity = (trainer.playback?.intensity ?? 1) * 100 }
        .confirmationDialog(
            "Finish and request reduced load?", isPresented: $confirmFinish, titleVisibility: .visible
        ) {
            Button("Finish workout", role: .destructive) { trainer.finishWorkout() }
        } message: {
            Text(
                "Progression ends and the app requests 0 W followed by stop. This does not guarantee zero resistance."
            )
        }
        .confirmationDialog(
            "Release without a Health save receipt?", isPresented: $confirmRelease,
            titleVisibility: .visible
        ) {
            Button("Release coordination", role: .destructive) { watch.releaseFinishedCoordination() }
        } message: {
            Text(
                "This does not confirm a Health save or end a Watch recording. End any active Watch session before starting another."
            )
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if let playback = trainer.playback, playback.state != .completed {
                if playback.state == .running {
                    Button("Pause", systemImage: "pause.fill") { trainer.pauseWorkout() }
                        .buttonStyle(.borderedProminent)
                } else if [.paused, .interrupted].contains(playback.state), playback.position != nil {
                    Button("Resume", systemImage: "play.fill") { watch.resumeRide() }
                        .buttonStyle(.borderedProminent).disabled(!trainer.readyToRide)
                } else {
                    ProgressView().accessibilityLabel(playback.state.title)
                }
                Spacer()
                Button("Finish", systemImage: "stop.fill", role: .destructive) { confirmFinish = true }
                    .buttonStyle(.bordered).disabled(playback.state == .finishing)
            }
        }
        .controlSize(.large).frame(minHeight: trainer.workoutOwnsTrainer ? 54 : 0)
        .padding(.horizontal).padding(.vertical, trainer.workoutOwnsTrainer ? 8 : 0)
        .background(.regularMaterial)
    }

    private func liveMetrics(_ playback: WorkoutPlayback) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fresh =
                trainer.telemetryDate.map { (0...3).contains(context.date.timeIntervalSince($0)) } ?? false
            let hrFresh =
                watch.receivedAt.map { (0...10).contains(context.date.timeIntervalSince($0)) } ?? false
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                MetricTile(
                    title: "Measured power", value: fresh ? trainer.power.map(String.init) : nil, unit: "W",
                    symbol: "bolt.fill")
                MetricTile(
                    title: "Scheduled target", value: playback.position.map { String($0.targetWatts) },
                    unit: "W", symbol: "scope")
                MetricTile(
                    title: "Heart rate",
                    value: hrFresh ? watch.heartRate.map { String(Int($0.rounded())) } : nil, unit: "bpm",
                    symbol: "heart.fill")
                MetricTile(
                    title: "Cadence", value: fresh ? trainer.cadence.map { String(Int($0.rounded())) } : nil,
                    unit: "rpm", symbol: "arrow.triangle.2.circlepath")
                if let simulation = trainer.simulation {
                    let simulationFresh =
                        playback.state == .running
                        && (simulation.metrics.date.map { (0...3).contains(context.date.timeIntervalSince($0)) }
                            ?? false)
                    MetricTile(
                        title: "Simulated speed",
                        value: simulationFresh
                            ? simulation.metrics.speed.map {
                                ($0 * 3.6).formatted(.number.precision(.fractionLength(1)))
                            } : nil,
                        unit: "km/h", symbol: "speedometer")
                    MetricTile(
                        title: "Simulated distance",
                        value: (simulation.metrics.distance / 1000).formatted(
                            .number.precision(.fractionLength(2))),
                        unit: "km", symbol: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
        }
    }

    private func profile(_ playback: WorkoutPlayback) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workout profile").font(.headline)
            Chart {
                ForEach(Array(playback.workout.intervals.enumerated()), id: \.offset) { index, interval in
                    let start = playback.workout.intervals.prefix(index).reduce(0) { $0 + $1.duration }
                    ForEach(0..<2, id: \.self) { endpoint in
                        let x = endpoint == 0 ? start : start + interval.duration
                        let y =
                            (endpoint == 0 ? interval.startPower : interval.endPower) * playback.ftp
                            * playback.intensity
                        AreaMark(
                            x: .value("Active minutes", x / 60), y: .value("Target watts", y),
                            series: .value("Interval", index)
                        )
                        .foregroundStyle(Color.teal.opacity(0.18))
                        LineMark(
                            x: .value("Active minutes", x / 60), y: .value("Target watts", y),
                            series: .value("Interval", index)
                        )
                        .foregroundStyle(
                            index == playback.position?.index ? Color.teal : Color.teal.opacity(0.5))
                    }
                }
                RuleMark(x: .value("Now", playback.elapsed / 60)).foregroundStyle(.primary)
            }.frame(height: 120)
                .chartXAxisLabel("Active minutes").chartYAxisLabel("Target W")
                .chartLegend(.hidden)
                .accessibilityLabel(
                    "Workout target profile. Interval \(playback.position.map { $0.index + 1 } ?? playback.workout.intervals.count)."
                )
        }.rideCard()
    }

    @ViewBuilder private var recordingSummary: some View {
        if watch.isWatchRide, let recording = watch.recordingMetrics {
            VStack(alignment: .leading, spacing: 10) {
                Text("Watch summary").font(.headline)
                LabeledContent(
                    "Average heart rate",
                    value: recording.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "Unavailable")
                LabeledContent(
                    "Maximum heart rate",
                    value: recording.maximumHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "Unavailable")
                LabeledContent(
                    "Active energy",
                    value: recording.activeKilocalories.map {
                        "\($0.formatted(.number.precision(.fractionLength(0)))) kcal"
                    } ?? "Unavailable")
                LabeledContent(
                    "Total energy",
                    value: recording.totalKilocalories.map {
                        "\($0.formatted(.number.precision(.fractionLength(0)))) kcal"
                    } ?? "Unavailable")
                Text("Last received Watch/HealthKit estimates. Missing values are not zero.").font(.caption)
                    .foregroundStyle(.secondary)
            }.rideCard()
        }
    }

    private func clock(_ seconds: Double) -> String {
        "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }
    private func stateIcon(_ state: WorkoutPlayback.State) -> String {
        switch state {
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .paused, .pausing: "pause.circle.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        default: "clock"
        }
    }

    private func guidanceLabel(_ status: CadenceGuidanceEvaluator.Status) -> String {
        switch status {
        case .unavailable: "Cadence guidance unavailable"
        case .grace: "Settle into your cadence"
        case .increaseCadence: "Increase cadence gently"
        case .withinRange: "Cadence within range"
        case .easeCadence: "Ease cadence gently"
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String?
    let unit: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            if let value {
                Text(value).font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65).lineLimit(1)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Unavailable").font(.headline)
                Text("Waiting for fresh data").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 105, alignment: .leading).rideCard()
            .accessibilityElement(children: .combine)
    }
}

extension View {
    func rideCard() -> some View {
        padding(16).background(
            Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
