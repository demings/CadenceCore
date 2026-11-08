import HealthKit
import Observation
import SwiftUI
import WatchConnectivity

@main
struct CadenceCoreWatchApp: App {
    @State private var workout = WatchWorkout()
    @State private var confirmFinish = false
    @State private var confirmLocalEnd = false
    @State private var showingDiagnostics = false
    @State private var confirmClearRecovery = false
    @State private var watchPage = 0
    @State private var showingIntensity = false
    @State private var intensity = 100.0
    private var currentIntensityPercent: Int {
        Int((workout.snapshot?.intensity ?? 1.0) * 100.0)
    }

    @ViewBuilder private var activeControls: some View {
        if workout.snapshot?.state == "running" {
            Button("Pause", systemImage: "pause.fill") { workout.control(.pause) }
                .disabled(workout.saving || workout.commandPending)
        }
        if ["paused", "interrupted"].contains(workout.snapshot?.state ?? ""),
            workout.snapshot?.interval != nil
        {
            Button("Resume", systemImage: "play.fill") { workout.control(.resume) }
                .disabled(workout.saving || workout.commandPending || workout.linkStale)
        }
        Button("Finish and save", role: .destructive) { confirmFinish = true }
            .disabled(workout.saving || workout.commandPending || workout.linkStale)
        if ["running", "paused"].contains(workout.snapshot?.state ?? "") {
            Button("Intensity · \(currentIntensityPercent)%") {
                intensity = Double(currentIntensityPercent)
                showingIntensity = true
            }.disabled(workout.saving || workout.commandPending || workout.linkStale)
        }
        if workout.linkStale {
            if workout.mayReconnect {
                Button("Reconnect existing ride", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await workout.reconnectRide() }
                }
                Text("Recover and prepare the matching ride on iPhone first. This resumes the existing recording, not a new workout.")
                    .font(.caption2)
            }
        }
        if workout.mayEndLocally {
            Button("End locally", role: .destructive) { confirmLocalEnd = true }
            Text("Ending locally cannot reduce trainer load. Stop pedaling; use iPhone controls when available.")
                .font(.caption2)
        }
    }

    @ViewBuilder private var preparedControls: some View {
        if let staged = workout.staged {
            Text(staged.name).font(.headline)
            Text("\(Int(staged.duration / 60.0)) min · FTP \(Int(staged.ftp)) W").font(.caption)
            Button("Start workout", systemImage: "play.fill") { Task { await workout.start(staged) } }
                .disabled(workout.starting || workout.recovering || workout.recoveryBlocked)
            Text("iPhone must stay connected to the trainer. Recorded on Watch and saved to Health.")
                .font(.caption2)
            if let simulation = staged.simulation {
                Text(simulationDescription(simulation))
                    .font(.caption2)
            }
        }
        Button("Troubleshooting") { showingDiagnostics = true }
    }

    private func simulationDescription(_ simulation: SimulationConfiguration) -> String {
        let mass = simulation.riderMass.formatted(.number.precision(.fractionLength(0...1)))
        let consent = simulation.saveToHealth ? "on" : "off"
        return "Flat-road estimates · \(mass) kg rider. Simulated Health speed/distance \(consent)."
    }

    private var sessionContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("CadenceCore").font(.headline)
                Text(workout.status).font(.caption)
                if workout.active, let recording = workout.recordingMetrics {
                    VStack(spacing: 4) {
                        Text("Recording summary").font(.headline)
                        Text(recording.activeKilocalories.map { "\(Int($0.rounded())) active kcal" } ?? "Active energy unavailable")
                        Text(recording.totalKilocalories.map { "\(Int($0.rounded())) total kcal" } ?? "Total energy unavailable")
                        Text(recording.averageHeartRate.map { "\(Int($0.rounded())) bpm average" } ?? "Average heart rate unavailable")
                    }.font(.caption)
                }
                if let issue = workout.recordingError {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
                if workout.recovering { ProgressView("Checking previous session…") }
                if workout.recoveryBlocked {
                    if !workout.active {
                        Button("Retry session check") { workout.retrySessionCheck() }
                            .disabled(workout.recovering || workout.starting || workout.saving)
                    }
                    Button("Check saved workout") { Task { await workout.reconcileSave() } }
                        .disabled(!workout.mayCheckSavedWorkout)
                    Button("Clear recovery warning", role: .destructive) { confirmClearRecovery = true }
                    Text("Review Health first. Clearing does not save or delete a Health workout and does not stop trainer resistance.")
                        .font(.caption2)
                }
                if workout.starting {
                    ProgressView("Preparing session…")
                } else if workout.active, workout.ride != nil {
                    activeControls
                } else if workout.active {
                    Button("End and discard", role: .destructive) { workout.endDiagnostic() }
                } else if !workout.saving {
                    preparedControls
                }
            }.padding()
        }
    }

    private var intensitySheet: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Workout intensity").font(.headline)
                Text("\(Int(intensity))%").font(.largeTitle.monospacedDigit())
                HStack {
                    Button {
                        intensity = max(50, intensity - 5)
                    } label: {
                        Image(systemName: "minus").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Decrease intensity five percent")
                    Button {
                        intensity = min(150, intensity + 5)
                    } label: {
                        Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Increase intensity five percent")
                }
                Button("Apply intensity") {
                    workout.control(.intensity, requestedIntensity: intensity / 100)
                    showingIntensity = false
                }.disabled(workout.commandPending || workout.linkStale)
                Text("Changes targets, not FTP. Trainer limits are checked on iPhone.").font(.caption2)
            }.padding()
        }
    }

    private var diagnosticsSheet: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Troubleshooting").font(.headline)
                Button("Start HR diagnostic") {
                    showingDiagnostics = false
                    Task { await workout.start(nil) }
                }
                Text("HR diagnostics are discarded; they do not record a ride.").font(.caption2)
                if let error = UserDefaults.standard.string(forKey: "lastSessionError") {
                    Text(error).font(.caption2)
                }
            }.padding()
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $watchPage) {
                if workout.active {
                    ScrollView {
                        WatchRideMetrics(workout: workout)
                        Text("Swipe up for controls").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.horizontal).tag(0)
                }
                sessionContent.tag(workout.active ? 1 : 0)
            }.tabViewStyle(.verticalPage)
                .tint(Color("AccentColor"))
                .onChange(of: workout.active) { watchPage = 0 }
                .sheet(isPresented: $showingIntensity) { intensitySheet }
                .sheet(isPresented: $showingDiagnostics) { diagnosticsSheet }
                .confirmationDialog(
                    "Finish workout and save to Health?", isPresented: $confirmFinish,
                    titleVisibility: .visible
                ) {
                    Button("Finish and save", role: .destructive) { workout.control(.finish) }
                } message: {
                    Text(
                        "iPhone requests reduced load before Watch saves. Neither acknowledgment nor finish guarantees zero resistance."
                    )
                }
                .confirmationDialog(
                    "Clear recovery after reviewing Health?", isPresented: $confirmClearRecovery,
                    titleVisibility: .visible
                ) {
                    Button("Clear recovery", role: .destructive) { workout.clearRecovery() }
                } message: {
                    Text(
                        "No automatic save retry is performed to avoid duplicate workouts. Finish any recovered session locally first."
                    )
                }
                .confirmationDialog(
                    "End recording without trainer confirmation?", isPresented: $confirmLocalEnd,
                    titleVisibility: .visible
                ) {
                    Button("End locally and save", role: .destructive) { workout.endLocally() }
                } message: {
                    Text(
                        "The trainer may retain its last target. This only ends Watch recording; it does not release resistance."
                    )
                }
        }
    }
}

private struct WatchRideMetrics: View {
    @Bindable var workout: WatchWorkout

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                let hrFresh = workout.sampleDate.map { (0...10).contains(context.date.timeIntervalSince($0)) } ?? false
                if let snapshot = workout.snapshot {
                    let linkFresh = workout.lastSnapshotDate.map { (0...8).contains(context.date.timeIntervalSince($0)) } ?? false
                    let telemetryFresh =
                        linkFresh && (snapshot.telemetryDate.map { (0...3).contains(context.date.timeIntervalSince($0)) } ?? false)
                    Text(linkFresh ? snapshot.state.capitalized : "Connection lost").font(.caption.bold())
                        .foregroundStyle(linkFresh ? Color("AccentColor") : Color.orange)
                    VStack(spacing: 2) {
                        Text("Scheduled target").font(.caption2).foregroundStyle(.secondary)
                        Text(snapshot.target.map { "\($0) W" } ?? "Unavailable")
                            .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }.accessibilityElement(children: .combine)
                    HStack {
                        metric("Measured", value: telemetryFresh ? snapshot.power.map { "\($0) W" } : nil)
                        metric("Heart rate", value: hrFresh ? workout.heartRate.map { "\(Int($0.rounded())) bpm" } : nil)
                    }
                    HStack {
                        metric("Cadence", value: telemetryFresh ? snapshot.cadence.map { "\(Int($0.rounded())) rpm" } : nil)
                        metric("Active time", value: "\(Int(snapshot.elapsed) / 60):\(String(format: "%02d", Int(snapshot.elapsed) % 60))")
                    }
                    if let ride = workout.ride {
                        ProgressView(value: snapshot.elapsed, total: ride.duration).tint(Color("AccentColor"))
                    }
                    if let interval = snapshot.interval, let remaining = snapshot.remaining {
                        Text("Interval \(interval) · \(Int(ceil(remaining))) sec left").font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let guidance = snapshot.guidance, let target = guidance.target, linkFresh,
                        snapshot.state == "running"
                    {
                        VStack(spacing: 4) {
                            Text("\(Int(target.range.lower))–\(Int(target.range.upper)) rpm")
                                .font(.headline.monospacedDigit())
                            Text(
                                guidance.status == .increaseCadence
                                    ? "Increase gently"
                                    : guidance.status == .easeCadence
                                        ? "Ease gently" : guidance.status == .grace ? "Settle into cadence" : "Within range"
                            )
                            .font(.caption2)
                            Text(target.source == .workoutTarget ? "Workout cadence" : "Suggested cadence")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(10)
                            .background(Color("AccentColor").opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let cue = snapshot.cue, linkFresh, snapshot.state == "running" {
                        Text(cue).font(.callout.bold())
                    }
                    if let simulation = snapshot.simulation {
                        let simulationFresh =
                            linkFresh && snapshot.state == "running"
                            && (simulation.date.map { (0...3).contains(context.date.timeIntervalSince($0)) } ?? false)
                        VStack(spacing: 3) {
                            Text("Simulated travel").font(.caption2).foregroundStyle(.secondary)
                            Text("\((simulation.distance / 1000).formatted(.number.precision(.fractionLength(2)))) km")
                                .font(.headline.monospacedDigit())
                            if simulationFresh, let speed = simulation.speed {
                                Text("\((speed * 3.6).formatted(.number.precision(.fractionLength(1)))) km/h simulated")
                                    .font(.caption2)
                            }
                        }
                    }
                } else {
                    if workout.linkStale {
                        Text("iPhone link lost").font(.headline).foregroundStyle(.orange)
                        Text(workout.status).font(.caption)
                    } else {
                        ProgressView("Waiting for iPhone")
                    }
                    metric("Heart rate", value: hrFresh ? workout.heartRate.map { "\(Int($0.rounded())) bpm" } : nil)
                }
            }
        }
    }

    private func metric(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "Unavailable").font(.system(.headline, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

@MainActor @Observable
final class WatchWorkout: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate,
    WCSessionDelegate
{
    var status = "Choose a workout on iPhone, then Prepare ride on Watch."
    private(set) var active = false
    private(set) var starting = false
    private(set) var saving = false
    private(set) var heartRate: Double?
    private(set) var sampleDate: Date?
    private(set) var recordingMetrics: RecordingMetrics?
    private(set) var staged: RideDescriptor?
    private(set) var ride: RideDescriptor?
    private(set) var snapshot: RideSnapshot?
    private(set) var lastSnapshotDate: Date?
    private(set) var recordingError: String?
    private(set) var linkStale = false
    var commandPending: Bool { pendingCommand != nil }
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var collectionStart: Date?
    private var samples = TrainerSampleWindow()
    private var pendingCommand: RideMessage?
    private var heartbeat: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var lastSequence = -1
    private var finishing = false
    private var connectionStart: Date?
    private var recordingRunning = false
    private var mirrorDisconnected = false
    private var ending = false
    private var startPhase = WatchStartPhase.authorization
    private let checkpoint = WatchCheckpointStore()
    private(set) var recovering = true
    private(set) var recoveryBlocked = false
    private var recoveryRequest: UUID?
    private var recoveryTimeout: Task<Void, Never>?
    private var lastCheckpointDate: Date?
    private var lastCadenceHaptic: Double?
    var mayReconnect: Bool { active && ride != nil && !recoveryBlocked && !saving && !starting }
    var mayCheckSavedWorkout: Bool { checkpoint.value != nil && !recovering && !starting && !saving }
    var mayEndLocally: Bool {
        active && ride != nil && !saving && !starting && (linkStale || snapshot?.state == "interrupted" || recoveryBlocked)
    }

    override init() {
        super.init()
        if let savedStatus = UserDefaults.standard.string(forKey: "lastHealthSaveStatus") {
            status = savedStatus
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
        recoverSession()
    }

    func start(_ descriptor: RideDescriptor?) async {
        guard !active, !starting, !saving, !ending, !recovering, !recoveryBlocked else { return }
        starting = true
        defer { starting = false }
        startPhase = .authorization
        do {
            if let descriptor, !descriptor.isValid { throw RideLinkError.invalidMessage }
            var share: Set<HKSampleType> = [
                HKObjectType.workoutType(), HKQuantityType(.cyclingPower), HKQuantityType(.cyclingCadence),
                HKQuantityType(.activeEnergyBurned), HKQuantityType(.basalEnergyBurned),
            ]
            if descriptor?.simulation?.saveToHealth == true {
                share.insert(HKQuantityType(.cyclingSpeed))
                share.insert(HKQuantityType(.distanceCycling))
            }
            try await store.requestAuthorization(
                toShare: share,
                read: [
                    HKObjectType.workoutType(), HKQuantityType(.heartRate),
                    HKQuantityType(.activeEnergyBurned), HKQuantityType(.basalEnergyBurned),
                ])
            if descriptor != nil,
                store.authorizationStatus(for: HKObjectType.workoutType()) != .sharingAuthorized
            {
                status = "Allow CadenceCore to save workouts in Health settings before starting."
                UserDefaults.standard.set(status, forKey: "lastSessionError")
                reportToPhone(status)
                return
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .cycling
            configuration.locationType = .indoor
            startPhase = .creating
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            self.session = session
            self.builder = builder
            ride = descriptor
            snapshot = nil
            lastSequence = -1
            lastSnapshotDate = nil
            recordingError = nil
            recordingMetrics = nil
            if descriptor != nil {
                let unavailable = [
                    (HKQuantityType(.cyclingPower), "power"),
                    (HKQuantityType(.cyclingCadence), "cadence"),
                    (HKQuantityType(.activeEnergyBurned), "active energy"),
                    (HKQuantityType(.basalEnergyBurned), "resting energy"),
                ].filter { store.authorizationStatus(for: $0.0) != .sharingAuthorized }.map(\.1)
                if !unavailable.isEmpty {
                    recordingError =
                        "Health sharing is not enabled for \(unavailable.joined(separator: ", ")); the saved workout may omit these metrics."
                }
                if descriptor?.simulation?.saveToHealth == true,
                    store.authorizationStatus(for: HKQuantityType(.cyclingSpeed)) != .sharingAuthorized
                        || store.authorizationStatus(for: HKQuantityType(.distanceCycling))
                            != .sharingAuthorized
                {
                    recordingError = [
                        recordingError, "Simulated speed/distance sharing is not fully enabled in Health.",
                    ].compactMap { $0 }.joined(separator: " ")
                }
            }
            finishing = false
            linkStale = false
            mirrorDisconnected = false
            collectionStart = nil
            connectionStart = Date()
            recordingRunning = false
            samples = TrainerSampleWindow()
            heartRate = nil
            sampleDate = nil
            session.delegate = self
            builder.delegate = self
            configureDataSource(builder, configuration: configuration)
            active = true
            if descriptor != nil { persistCheckpoint(force: true) }
            if descriptor != nil {
                startPhase = .preparing
                session.prepare()
                try await waitForState(.prepared, session: session)
            } else {
                startPhase = .collecting
                let date = Date()
                session.startActivity(with: date)
                try await builder.beginCollection(at: date)
                collectionStart = date
                recordingRunning = true
            }
            startPhase = .mirroring
            try await session.startMirroringToCompanionDevice()
            if let descriptor {
                startPhase = .requesting
                status = "Waiting for iPhone trainer start…"
                let ready = RideMessage(rideID: descriptor.id, action: .ready)
                pendingCommand = ready
                try await send(ready)
                monitor()
            } else {
                startPhase = .recording
                persistCheckpoint(force: true)
                status = "Measuring HR; diagnostic will be discarded."
            }
        } catch {
            let failure = startPhase.failure(error)
            status = failure
            UserDefaults.standard.set(failure, forKey: "lastSessionError")
            if let session {
                session.end()
                do { try await waitForState(.ended, session: session) } catch {
                    status +=
                        " Cleanup incomplete: \(error.localizedDescription). Use End locally before starting again."
                    linkStale = true
                    reportToPhone(status)
                    return
                }
            }
            builder?.discardWorkout()
            if checkpoint.value?.saveAttempted != true { checkpoint.clear() }
            resetSession()
            reportToPhone(failure)
        }
    }

    private func configureDataSource(_ builder: HKLiveWorkoutBuilder, configuration: HKWorkoutConfiguration) {
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        builder.dataSource?.enableCollection(for: HKQuantityType(.activeEnergyBurned), predicate: nil)
        builder.dataSource?.enableCollection(for: HKQuantityType(.basalEnergyBurned), predicate: nil)
        for type in [
            HKQuantityType(.cyclingPower), HKQuantityType(.cyclingCadence),
            HKQuantityType(.distanceCycling), HKQuantityType(.cyclingSpeed),
        ] {
            builder.dataSource?.disableCollection(for: type)
        }
    }

    private func waitForState(_ state: HKWorkoutSessionState, session: HKWorkoutSession) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while session.state != state {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                state == .ended || session.state != .ended
            else {
                throw NSError(
                    domain: "CadenceCore.SessionLifecycle", code: state.rawValue,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Watch session did not reach \(state == .prepared ? "prepared" : "ended") within 8 seconds (current state \(session.state.rawValue))."
                    ])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func reportToPhone(_ failure: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            ["failure": failure, "stagedID": staged?.id.uuidString ?? ""], replyHandler: nil
        ) { error in
            Task { @MainActor in
                self.recordingError = "Error report delivery failed: \(error.localizedDescription)"
            }
        }
    }

    func control(_ action: RideAction, requestedIntensity: Double? = nil) {
        guard active, !saving, !commandPending, let ride else { return }
        guard [.pause, .resume, .finish, .intensity].contains(action) else { return }
        let message = RideMessage(
            rideID: ride.id, action: action, requestedIntensity: requestedIntensity)
        pendingCommand = message
        status = "Waiting for iPhone to confirm \(action.rawValue)…"
        Task {
            do { try await send(message) } catch {
                guard active, self.ride?.id == message.rideID,
                    pendingCommand?.commandID == message.commandID
                else { return }
                status =
                    "Control delivery failed: \(error.localizedDescription). Trainer state unconfirmed."
            }
        }
    }

    private func send(_ message: RideMessage) async throws {
        guard let session else { throw RideLinkError.invalidMessage }
        try await session.sendToRemoteWorkoutSession(data: JSONEncoder().encode(message))
    }

    private func monitor() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while let self, self.active, !self.finishing, let ride = self.ride {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                do {
                    if let pending = self.pendingCommand {
                        // Refresh transport age without changing command identity during retries.
                        try await self.send(
                            RideMessage(
                                rideID: ride.id, action: pending.action,
                                commandID: pending.commandID, requestedIntensity: pending.requestedIntensity))
                    } else {
                        try await self.send(
                            RideMessage(
                                rideID: ride.id, action: .heartbeat,
                                recording: self.recordingMetrics))
                    }
                } catch { self.status = "iPhone delivery failed: \(error.localizedDescription)" }
                if let last = self.lastSnapshotDate ?? self.connectionStart,
                    Date().timeIntervalSince(last) > 8, !self.linkStale
                {
                    self.linkStale = true
                    if self.recordingRunning {
                        self.session?.pause()
                        self.recordingRunning = false
                    }
                    self.status = "iPhone connection stale. Recording paused; trainer state unconfirmed."
                    do {
                        try await self.send(RideMessage(rideID: ride.id, action: .failure, detail: self.status))
                    } catch { self.status += " Warning delivery failed: \(error.localizedDescription)" }
                }
            }
        }
    }

    private func receive(_ packet: Data) async {
        guard !mirrorDisconnected else { return }
        var startingCollection = false
        do {
            let message = try RideMessage.decode(packet)
            guard active, message.rideID == ride?.id else { throw RideLinkError.invalidMessage }
            if message.action == .failure {
                status = message.detail ?? "iPhone rejected workout start."
                if collectionStart == nil {
                    heartbeat?.cancel()
                    pendingCommand = nil
                    linkStale = true
                    if let session {
                        session.end()
                        try await waitForState(.ended, session: session)
                    }
                    builder?.discardWorkout()
                    resetSession()
                } else if recordingRunning {
                    session?.pause()
                    recordingRunning = false
                }
                return
            }
            guard message.action == .snapshot, let update = message.snapshot,
                let descriptor = ride, update.elapsed <= descriptor.duration
            else { throw RideLinkError.invalidMessage }
            if let pendingCommand, pendingCommand.action == .ready,
                let acknowledgment = update.acknowledgedCommandID, acknowledgment != pendingCommand.commandID
            {
                return
            }
            guard update.sequence > lastSequence, let session, let builder else { return }
            guard update.simulation == nil || descriptor.simulation != nil,
                (update.simulation?.distance ?? 0) >= (snapshot?.simulation?.distance ?? 0)
            else {
                throw RideLinkError.invalidMessage
            }
            lastSequence = update.sequence
            snapshot = update
            lastSnapshotDate = Date()
            if update.state == "running", !mirrorDisconnected,
                descriptor.cadenceConfiguration?.hapticsEnabled == true,
                update.guidance?.recommendsHaptic == true,
                update.telemetryDate.map({ (0...3).contains(Date().timeIntervalSince($0)) }) == true,
                lastCadenceHaptic.map({ ProcessInfo.processInfo.systemUptime - $0 >= 30 }) ?? true
            {
                WKInterfaceDevice.current().play(.notification)
                lastCadenceHaptic = ProcessInfo.processInfo.systemUptime
            }
            linkStale = false
            if let pendingCommand {
                let confirmed: Bool
                switch pendingCommand.action {
                case .ready: confirmed = update.state != "ready"
                case .pause: confirmed = ["pausing", "paused", "interrupted"].contains(update.state)
                case .resume:
                    confirmed = ["settingTarget", "starting", "running", "interrupted"].contains(update.state)
                case .finish: confirmed = ["finishing", "completed", "interrupted"].contains(update.state)
                default: confirmed = true
                }
                if confirmed, update.acknowledgedCommandID.map({ $0 == pendingCommand.commandID }) ?? true {
                    self.pendingCommand = nil
                }
            }
            status = update.status
            if update.state == "running", pendingCommand?.action != .pause {
                if collectionStart == nil {
                    startingCollection = true
                    startPhase = .collecting
                    let date = message.date
                    session.startActivity(with: date)
                    try await builder.beginCollection(at: date)
                    guard self.session === session, active else { return }
                    collectionStart = date
                    recordingRunning = true
                    startingCollection = false
                    startPhase = .recording
                    if let ride {
                        try await builder.addMetadata([
                            HKMetadataKeyExternalUUID: ride.id.uuidString,
                            HKMetadataKeyWorkoutBrandName: "CadenceCore",
                            "CadenceCoreWorkoutName": ride.name,
                            "CadenceCoreFTP": ride.ftp,
                            "CadenceCoreTrainerMetrics": "Measured FTMS power and cadence",
                        ])
                        if let model = ride.simulation, model.saveToHealth {
                            try await builder.addMetadata([
                                "CadenceCoreSimulationModel": "Flat-road steady-state v\(model.version)",
                                "CadenceCoreSimulationParameters": String(
                                    decoding: JSONEncoder().encode(model), as: UTF8.self),
                                "CadenceCoreDistanceProvenance":
                                    "Simulated from measured FTMS power; aggregate active fresh-telemetry distance. No GPS.",
                            ])
                        }
                    }
                } else if !recordingRunning {
                    session.resume()
                    recordingRunning = true
                }
                guard self.session === session, active else { return }
            } else if collectionStart != nil,
                ["pausing", "paused", "finishing", "interrupted"].contains(update.state),
                recordingRunning
            {
                session.pause()
                recordingRunning = false
            }
            if let start = collectionStart,
                let window = samples.take(update, now: Date(), collectionStart: start),
                recordingRunning
            {
                var quantities: [HKQuantitySample] = []
                if let watts = update.power, watts >= 0,
                    store.authorizationStatus(for: HKQuantityType(.cyclingPower)) == .sharingAuthorized
                {
                    quantities.append(
                        HKQuantitySample(
                            type: HKQuantityType(.cyclingPower),
                            quantity: HKQuantity(unit: .watt(), doubleValue: Double(watts)),
                            start: window.start, end: window.end))
                }
                if let cadence = update.cadence,
                    store.authorizationStatus(for: HKQuantityType(.cyclingCadence)) == .sharingAuthorized
                {
                    quantities.append(
                        HKQuantitySample(
                            type: HKQuantityType(.cyclingCadence),
                            quantity: HKQuantity(
                                unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: cadence),
                            start: window.start, end: window.end))
                }
                if descriptor.simulation?.saveToHealth == true,
                    let simulated = update.simulation, let speed = simulated.speed,
                    let date = simulated.date, abs(date.timeIntervalSince(window.end)) <= 0.1,
                    store.authorizationStatus(for: HKQuantityType(.cyclingSpeed)) == .sharingAuthorized
                {
                    quantities.append(
                        HKQuantitySample(
                            type: HKQuantityType(.cyclingSpeed),
                            quantity: HKQuantity(
                                unit: HKUnit.meter().unitDivided(by: .second()), doubleValue: speed),
                            start: window.start, end: window.end,
                            metadata: ["CadenceCoreSimulated": true]))
                }
                if !quantities.isEmpty {
                    do { try await builder.addSamples(quantities) } catch {
                        recordingError =
                            "Trainer/simulated metrics were not recorded: \(error.localizedDescription)"
                    }
                }
            }
            if update.state == "completed" {
                await finishRecording(confirmedTrainerStop: true)
            } else {
                persistCheckpoint(force: update.state != "running")
            }
        } catch {
            recordingError =
                startingCollection
                ? WatchStartPhase.collecting.failure(error)
                : "Workout communication/recording failed: \(error.localizedDescription) [\((error as NSError).domain):\((error as NSError).code)]"
            if startingCollection {
                UserDefaults.standard.set(recordingError, forKey: "lastSessionError")
                reportToPhone(recordingError ?? "Health recording failed.")
            }
            if recordingRunning {
                session?.pause()
                recordingRunning = false
            }
            if let ride {
                do {
                    try await send(RideMessage(rideID: ride.id, action: .failure, detail: recordingError))
                } catch { status = "Failure delivery failed: \(error.localizedDescription)" }
            }
        }
    }

    func endDiagnostic() {
        guard ride == nil, !ending else { return }
        ending = true
        Task {
            defer { ending = false }
            if let session {
                session.end()
                do { try await waitForState(.ended, session: session) } catch {
                    status = "Diagnostic end unconfirmed: \(error.localizedDescription)"
                    return
                }
            }
            builder?.discardWorkout()
            resetSession()
            status = "Ended. Diagnostic discarded."
        }
    }

    func endLocally() {
        let previous = processing
        processing = Task {
            await previous?.value
            if recoveryBlocked, checkpoint.value?.saveAttempted == true {
                if let session {
                    session.end()
                    do { try await waitForState(.ended, session: session) } catch {
                        status = "Recovered session end failed: \(error.localizedDescription)"
                        return
                    }
                }
                resetSession()
                status =
                    "Recovered session ended. Previous save is unconfirmed; inspect Health. No duplicate save attempted."
                return
            }
            await finishRecording(confirmedTrainerStop: false)
        }
    }

    private func finishRecording(confirmedTrainerStop: Bool) async {
        guard !finishing, checkpoint.value?.saveAttempted != true,
            let ride, let builder, let session
        else { return }
        finishing = true
        saving = true
        heartbeat?.cancel()
        pendingCommand = nil
        let end = Date()
        session.end()
        do {
            try await waitForState(.ended, session: session)
            if collectionStart != nil {
                var metadata: [String: Any] = [
                    "CadenceCoreTrainerStopConfirmed": confirmedTrainerStop,
                    "CadenceCoreSimulationHealthEnabled": ride.simulation?.saveToHealth == true,
                ]
                if let elapsed = snapshot?.elapsed {
                    metadata["CadenceCoreActiveDurationSeconds"] = elapsed
                }
                if let distance = snapshot?.simulation?.distance, ride.simulation?.saveToHealth == true {
                    metadata["CadenceCoreExpectedDistanceMeters"] = distance
                }
                if let recordingError { metadata["CadenceCoreRecordingWarning"] = recordingError }
                try await builder.addMetadata(metadata)
                if let start = collectionStart, ride.simulation?.saveToHealth == true,
                    let distance = snapshot?.simulation?.distance,
                    store.authorizationStatus(for: HKQuantityType(.distanceCycling)) == .sharingAuthorized
                {
                    // One aggregate sample preserves the iPhone total even when mirrored speed packets are lost.
                    do {
                        try await builder.addSamples([
                            HKQuantitySample(
                                type: HKQuantityType(.distanceCycling),
                                quantity: HKQuantity(unit: .meter(), doubleValue: distance), start: start, end: end,
                                metadata: ["CadenceCoreSimulated": true, "CadenceCoreAggregateDistance": true])
                        ])
                    } catch {
                        recordingError = "Simulated distance was not recorded: \(error.localizedDescription)"
                    }
                }
                try await builder.endCollection(at: end)
                updateRecordingMetrics(builder)
                if let recordingError {
                    try await builder.addMetadata(["CadenceCoreRecordingWarning": recordingError])
                }
                guard
                    checkpoint.save(
                        WatchRecordingCheckpoint(
                            ride: ride, collectionStart: collectionStart,
                            snapshot: snapshot, saveAttempted: true, receipt: nil))
                else {
                    throw NSError(
                        domain: "CadenceCore.Recovery", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: checkpoint.error ?? "Save checkpoint failed."])
                }
                guard let saved = try await builder.finishWorkout() else {
                    throw RideLinkError.noSavedWorkout
                }
                status = "Saved to Health."
                if !confirmedTrainerStop { status += " Trainer stop was NOT confirmed." }
                if recordingError != nil { status += " Some metrics were not recorded; see the warning." }
                if let distance = snapshot?.simulation?.distance, ride.simulation?.saveToHealth == true {
                    status +=
                        " \((distance / 1000).formatted(.number.precision(.fractionLength(2)))) km simulated (Health inclusion depends on permission/save result)."
                }
                UserDefaults.standard.set(status, forKey: "lastHealthSaveStatus")
                let receipt = RideMessage(
                    rideID: ride.id, action: .saved, date: end, snapshot: snapshot,
                    detail: "\(status) Health workout \(saved.uuid.uuidString).",
                    recording: recordingMetrics, savedWorkoutID: saved.uuid)
                _ = checkpoint.save(
                    WatchRecordingCheckpoint(
                        ride: ride, collectionStart: collectionStart,
                        snapshot: snapshot, saveAttempted: true, receipt: receipt))
                if deliverReceipt(receipt) { checkpoint.clear() }
            } else {
                builder.discardWorkout()
                status = "Ended before recording started. No workout saved."
                deliverReceipt(RideMessage(rideID: ride.id, action: .saved, date: end, snapshot: snapshot, detail: status))
                checkpoint.clear()
            }
            staged = nil
        } catch {
            if session.state != .ended {
                finishing = false
                saving = false
                linkStale = true
                status =
                    "Watch session has not ended: \(error.localizedDescription). Retry End locally; trainer stop is unconfirmed."
                recordingError = status
                return
            }
            recordingError =
                "Health save failed: \(error.localizedDescription). No automatic retry to avoid duplicate saves."
            status = "Workout ended; save is unconfirmed."
            UserDefaults.standard.set("\(status) \(recordingError ?? "")", forKey: "lastHealthSaveStatus")
            deliverReceipt(RideMessage(rideID: ride.id, action: .failure, date: end, snapshot: snapshot, detail: recordingError))
            recoveryBlocked = checkpoint.value?.saveAttempted == true
        }
        resetSession()
        saving = false
    }

    @discardableResult private func deliverReceipt(_ message: RideMessage) -> Bool {
        do {
            guard WCSession.default.activationState == .activated else {
                throw RideLinkError.invalidMessage
            }
            WCSession.default.transferUserInfo(["receipt": try JSONEncoder().encode(message)])
            return true
        } catch {
            recordingError = "Could not queue Health save result to iPhone: \(error.localizedDescription)"
            return false
        }
    }

    private func resetSession() {
        heartbeat?.cancel()
        active = false
        session = nil
        builder = nil
        heartRate = nil
        sampleDate = nil
        ride = nil
        pendingCommand = nil
        recordingRunning = false
        connectionStart = nil
    }

    private func persistCheckpoint(force: Bool) {
        guard let ride, !finishing,
            force || lastCheckpointDate.map({ Date().timeIntervalSince($0) >= 5 }) ?? true
        else { return }
        lastCheckpointDate = Date()
        if !checkpoint.save(
            WatchRecordingCheckpoint(
                ride: ride, collectionStart: collectionStart,
                snapshot: snapshot, saveAttempted: false, receipt: nil))
        {
            recordingError = checkpoint.error
        }
    }

    func retrySessionCheck() {
        guard !active, !starting, !saving, !ending else {
            status = "Finish the current Watch operation before retrying recovery."
            return
        }
        recoverSession()
    }

    private func recoverSession() {
        recoveryTimeout?.cancel()
        let request = UUID()
        recoveryRequest = request
        recovering = true
        recoveryBlocked = false
        status = "Checking the previous Watch session before preparing a new ride."
        recoveryTimeout = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch is CancellationError { return } catch {
                guard recoveryRequest == request else { return }
                recoveryRequest = nil
                recovering = false
                recoveryBlocked = true
                status = "Session-check timeout monitoring failed: \(error.localizedDescription). Review Health before retrying."
                return
            }
            guard recoveryRequest == request else { return }
            recoveryRequest = nil
            recovering = false
            recoveryBlocked = true
            status = "Session check timed out. Retry, or review Health and any active Apple Workout before clearing recovery."
        }
        store.recoverActiveWorkoutSession { recovered, error in
            Task { @MainActor in
                guard self.recoveryRequest == request else { return }
                self.recoveryRequest = nil
                self.recoveryTimeout?.cancel()
                defer {
                    self.recovering = false
                    if !self.active, !self.recoveryBlocked {
                        self.status = "Prepare a workout on iPhone, then start here."
                        self.acceptStage(WCSession.default.receivedApplicationContext)
                    }
                }
                if let error {
                    self.status = "Previous Watch session check failed: \(error.localizedDescription)"
                    self.recoveryBlocked = true
                    return
                }
                if let recovered {
                    self.session = recovered
                    recovered.delegate = self
                    self.builder = recovered.associatedWorkoutBuilder()
                    self.builder?.delegate = self
                    if let builder = self.builder {
                        self.configureDataSource(builder, configuration: recovered.workoutConfiguration)
                    }
                    self.active = true
                    self.linkStale = true
                    self.mirrorDisconnected = true
                    recovered.pause()
                    if let saved = self.checkpoint.value {
                        self.ride = saved.ride
                        self.collectionStart = saved.collectionStart
                        self.snapshot = saved.snapshot
                        self.staged = saved.ride
                        self.recoveryBlocked = saved.saveAttempted
                    } else {
                        self.recordingError =
                            "Recovered Health session without ride metadata. End and discard the unidentified session."
                    }
                    self.status =
                        "Recovered Watch recording, paused. Finish trainer on iPhone, then End locally. No automatic trainer resume."
                    if self.recoveryBlocked { await self.reconcileSave() }
                } else if self.checkpoint.value != nil || self.checkpoint.error != nil {
                    self.recoveryBlocked = true
                    self.status =
                        self.checkpoint.error
                        ?? "Previous recording ended without a confirmed save. Review Health before clearing recovery."
                    await self.reconcileSave()
                }
            }
        }
    }

    func reconcileSave() async {
        guard let saved = checkpoint.value else {
            status =
                checkpoint.error
                ?? "No saved checkpoint is available. Review Health before clearing recovery."
            return
        }
        if let receipt = saved.receipt {
            do { try await endRecoveredAfterSaveConfirmation() } catch {
                status = "Saved recording cleanup failed: \(error.localizedDescription)"
                return
            }
            guard deliverReceipt(receipt) else { return }
            checkpoint.clear()
            recoveryBlocked = false
            status = receipt.detail ?? "Previous Health save confirmed."
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: [saved.ride.id.uuidString])
            let workouts = try await HKSampleQueryDescriptor(
                predicates: [.workout(predicate)],
                sortDescriptors: [], limit: 2
            ).result(for: store)
            guard workouts.count == 1, let workout = workouts.first else {
                status =
                    "Health save unconfirmed: no unique accessible workout. Permission/sync may hide it; no automatic retry. Review Health."
                return
            }
            try await endRecoveredAfterSaveConfirmation()
            guard
                deliverReceipt(
                    RideMessage(
                        rideID: saved.ride.id, action: .saved,
                        detail: "Recovered saved Health workout.", savedWorkoutID: workout.uuid))
            else { return }
            checkpoint.clear()
            recoveryBlocked = false
            status = "Previous Health save confirmed."
            if session?.state == .ended { resetSession() }
        } catch {
            status =
                "Health save reconciliation failed: \(error.localizedDescription). Review Health; no save retry."
        }
    }

    func clearRecovery() {
        guard !active else {
            status = "End the recovered Watch session locally before clearing recovery."
            return
        }
        recoveryTimeout?.cancel()
        recoveryRequest = nil
        recovering = false
        checkpoint.clear()
        recoveryBlocked = false
        status = "Recovery cleared after user review. Previous Health save is not confirmed."
        acceptStage(WCSession.default.receivedApplicationContext)
    }

    func reconnectRide() async {
        guard mayReconnect, let session, let ride else { return }
        starting = true
        defer { starting = false }
        do {
            session.pause()
            recordingRunning = false
            if mirrorDisconnected { try await session.startMirroringToCompanionDevice() }
            mirrorDisconnected = false
            linkStale = false
            connectionStart = Date()
            lastSnapshotDate = nil
            lastSequence = -1
            let ready = RideMessage(rideID: ride.id, action: .ready, snapshot: snapshot)
            pendingCommand = ready
            try await send(ready)
            monitor()
            status = "Waiting for iPhone to confirm recovered trainer resume."
        } catch {
            linkStale = true
            status =
                "Existing ride reconnect failed: \(error.localizedDescription). Finish trainer and end recording locally."
        }
    }

    private func endRecoveredAfterSaveConfirmation() async throws {
        if let session, session.state != .ended {
            session.end()
            try await waitForState(.ended, session: session)
        }
        resetSession()
    }

    private func acceptStage(_ context: [String: Any]) {
        if recovering {
            status = "Checking the previous Watch session before preparing a new ride."
            return
        }
        if recoveryBlocked {
            status = "Recording recovery needs attention. Review the previous Health save before preparing another ride."
            return
        }
        guard !active, !starting, !saving else {
            status = "A workout is active. Finish it before loading another."
            return
        }
        guard let data = context["stage"] as? Data else {
            staged = nil
            return
        }
        do {
            guard data.count <= 8192 else { throw RideLinkError.invalidMessage }
            let descriptor = try JSONDecoder().decode(RideDescriptor.self, from: data)
            guard descriptor.isValid else { throw RideLinkError.invalidMessage }
            staged = descriptor
            status = "Workout ready."
            acknowledgeStage()
        } catch { status = "Invalid staged workout: \(error.localizedDescription)" }
    }

    private func acknowledgeStage() {
        guard let staged, WCSession.default.isReachable, !active else { return }
        WCSession.default.sendMessage(["stagedID": staged.id.uuidString], replyHandler: nil) { error in
            Task { @MainActor in
                self.status = "Workout loaded; iPhone acknowledgment failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in acknowledgeStage() }
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let data = session.receivedApplicationContext["stage"] as? Data
        Task { @MainActor in
            if let error {
                status = "Watch connection activation failed: \(error.localizedDescription)"
                return
            }
            acceptStage(data.map { ["stage": $0] } ?? [:])
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        // Decode the Sendable descriptor before crossing the actor boundary.
        let data = applicationContext["stage"] as? Data
        Task { @MainActor in acceptStage(data.map { ["stage": $0] } ?? [:]) }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        Task { @MainActor in
            guard session === workoutSession, !finishing, !starting, !ending else { return }
            if toState == .paused, recordingRunning, ride != nil {
                recordingRunning = false
                control(.pause)
                return
            }
            if toState == .running, !recordingRunning, collectionStart != nil, ride != nil {
                // A system-side resume must not restart ERG or recording before trainer confirmation.
                session?.pause()
                return
            }
            guard toState == .ended else { return }
            if ride == nil {
                endDiagnostic()
            } else {
                linkStale = true
                status =
                    "Watch session ended unexpectedly. Trainer stop is unconfirmed; end locally to save."
                if let ride {
                    do {
                        try await send(RideMessage(rideID: ride.id, action: .failure, detail: status))
                    } catch { status += " iPhone notification failed: \(error.localizedDescription)" }
                }
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            status = (starting ? startPhase : .recording).failure(error)
            UserDefaults.standard.set(status, forKey: "lastSessionError")
            reportToPhone(status)
            recordingError = status
            linkStale = true
            if starting { return }
            if let ride {
                do { try await send(RideMessage(rideID: ride.id, action: .failure, detail: status)) } catch {
                    status += " iPhone notification failed: \(error.localizedDescription)"
                }
            } else {
                endDiagnostic()
                status = "Diagnostic failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            let previous = processing
            processing = Task {
                await previous?.value
                guard session === workoutSession else { return }
                for packet in data {
                    guard session === workoutSession else { return }
                    await receive(packet)
                }
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in
            guard session === workoutSession, !finishing else { return }
            linkStale = true
            mirrorDisconnected = true
            if recordingRunning {
                session?.pause()
                recordingRunning = false
            }
            status =
                "iPhone mirroring disconnected: \(error?.localizedDescription ?? "Connection ended"). Trainer state unconfirmed."
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor in
            guard active, builder === workoutBuilder else { return }
            updateRecordingMetrics(workoutBuilder)
            guard collectedTypes.contains(HKQuantityType(.heartRate)),
                let statistics = workoutBuilder.statistics(for: HKQuantityType(.heartRate)),
                let quantity = statistics.mostRecentQuantity(),
                let interval = statistics.mostRecentQuantityDateInterval()
            else { return }
            let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            heartRate = bpm
            sampleDate = interval.end
            do {
                try await send(
                    RideMessage(
                        rideID: ride?.id, action: .heartRate, date: interval.end, bpm: bpm,
                        recording: recordingMetrics))
            } catch {
                guard active, builder === workoutBuilder else { return }
                status = "HR measured locally; iPhone delivery failed: \(error.localizedDescription)"
            }

        }
    }

    private func updateRecordingMetrics(_ builder: HKLiveWorkoutBuilder) {
        let heartRate = builder.statistics(for: HKQuantityType(.heartRate))
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let metrics = RecordingMetrics(
            averageHeartRate: heartRate?.averageQuantity()?.doubleValue(for: bpm),
            maximumHeartRate: heartRate?.maximumQuantity()?.doubleValue(for: bpm),
            activeKilocalories: builder.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie()),
            restingKilocalories: builder.statistics(for: HKQuantityType(.basalEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie()))
        guard metrics.isValid else {
            recordingMetrics = nil
            recordingError =
                "Watch returned invalid recording summary metrics; they are not displayed or mirrored."
            return
        }
        recordingMetrics = metrics
    }
}
