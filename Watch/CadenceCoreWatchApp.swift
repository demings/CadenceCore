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

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 12) {
                    Text("CadenceCore").font(.headline)
                    Text(workout.status).font(.caption)
                    if let issue = workout.recordingError { Text(issue).font(.caption).foregroundStyle(.orange) }
                    if workout.active { WatchRideMetrics(workout: workout) }
                    if workout.starting {
                        ProgressView("Preparing session…")
                    } else if workout.active, workout.ride != nil {
                        if workout.snapshot?.state == "running" {
                            Button("Pause", systemImage: "pause.fill") { workout.control(.pause) }
                                .disabled(workout.commandPending)
                        }
                        if ["paused", "interrupted"].contains(workout.snapshot?.state ?? ""),
                           workout.snapshot?.interval != nil {
                            Button("Resume", systemImage: "play.fill") { workout.control(.resume) }
                                .disabled(workout.commandPending || workout.linkStale)
                        }
                        Button("Finish and save", role: .destructive) { confirmFinish = true }
                            .disabled(workout.saving)
                        if workout.linkStale {
                            Button("End locally", role: .destructive) { confirmLocalEnd = true }
                            Text("Ending locally cannot reduce trainer load. Stop pedaling; use iPhone controls when available.")
                                .font(.caption2)
                        }
                    } else if workout.active {
                        Button("End and discard", role: .destructive) { workout.endDiagnostic() }
                    } else if !workout.saving {
                        if let staged = workout.staged {
                            Text(staged.name).font(.headline)
                            Text("\(Int(staged.duration / 60)) min · FTP \(Int(staged.ftp)) W").font(.caption)
                            Button("Start workout", systemImage: "play.fill") { Task { await workout.start(staged) } }
                                .disabled(workout.starting)
                            Text("iPhone must stay connected to the trainer. Recorded on Watch and saved to Health.")
                                .font(.caption2)
                            if let simulation = staged.simulation {
                                Text("Flat-road estimates · \(simulation.riderMass.formatted()) kg rider. Simulated Health speed/distance \(simulation.saveToHealth ? "on" : "off").")
                                    .font(.caption2)
                            }
                        }
                        Button("Troubleshooting") { showingDiagnostics = true }
                    }
                }
                .padding()
            }
            .tint(.teal)
            .sheet(isPresented: $showingDiagnostics) {
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
            .confirmationDialog("Finish workout and save to Health?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Finish and save", role: .destructive) { workout.control(.finish) }
            } message: {
                Text("iPhone requests reduced load before Watch saves. Neither acknowledgment nor finish guarantees zero resistance.")
            }
            .confirmationDialog("End recording without trainer confirmation?", isPresented: $confirmLocalEnd, titleVisibility: .visible) {
                Button("End locally and save", role: .destructive) { workout.endLocally() }
            } message: {
                Text("The trainer may retain its last target. This only ends Watch recording; it does not release resistance.")
            }
        }
    }
}

private struct WatchRideMetrics: View {
    @Bindable var workout: WatchWorkout

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                let fresh = workout.sampleDate.map { context.date.timeIntervalSince($0) <= 10 } ?? false
                Text(fresh ? workout.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "Waiting for HR" : "HR unavailable")
                    .font(.title2.monospacedDigit())
                if let snapshot = workout.snapshot {
                    let linkFresh = workout.lastSnapshotDate.map { context.date.timeIntervalSince($0) <= 8 } ?? false
                    Text(linkFresh ? snapshot.state.capitalized : "iPhone disconnected").font(.headline)
                    Text("\(Int(snapshot.elapsed) / 60):\(String(format: "%02d", Int(snapshot.elapsed) % 60))")
                        .font(.title2.monospacedDigit())
                    if let target = snapshot.target { Text("Scheduled \(target) W") }
                    let telemetryFresh = linkFresh && (snapshot.telemetryDate.map { context.date.timeIntervalSince($0) <= 3 } ?? false)
                    Text(telemetryFresh ? snapshot.power.map { "\($0) W measured" } ?? "Power unavailable" : "Power unavailable / stale")
                    Text(telemetryFresh ? snapshot.cadence.map { "\(Int($0.rounded())) rpm" } ?? "Cadence unavailable" : "Cadence unavailable / stale")
                    if let simulation = snapshot.simulation {
                        let simulationFresh = linkFresh && snapshot.state == "running" &&
                            (simulation.date.map { context.date.timeIntervalSince($0) <= 3 } ?? false)
                        Text(simulationFresh
                             ? simulation.speed.map { "\(($0 * 3.6).formatted(.number.precision(.fractionLength(1)))) km/h simulated" } ?? "Simulated speed unavailable"
                             : "Simulated speed unavailable / paused")
                        Text("\((simulation.distance / 1000).formatted(.number.precision(.fractionLength(2)))) km simulated")
                    }
                    if let interval = snapshot.interval, let remaining = snapshot.remaining {
                        Text("Interval \(interval) · \(Int(ceil(remaining))) sec left").font(.caption)
                    }
                }
            }
        }
    }
}

@MainActor @Observable
final class WatchWorkout: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, WCSessionDelegate {
    var status = "Choose a workout on iPhone, then Prepare ride on Watch."
    private(set) var active = false
    private(set) var starting = false
    private(set) var saving = false
    private(set) var heartRate: Double?
    private(set) var sampleDate: Date?
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

    override init() {
        super.init()
        if let savedStatus = UserDefaults.standard.string(forKey: "lastHealthSaveStatus") { status = savedStatus }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func start(_ descriptor: RideDescriptor?) async {
        guard !active, !starting, !saving, !ending else { return }
        starting = true
        defer { starting = false }
        startPhase = .authorization
        do {
            if let descriptor, !descriptor.isValid { throw RideLinkError.invalidMessage }
            var share: Set<HKSampleType> = [
                HKObjectType.workoutType(), HKQuantityType(.cyclingPower), HKQuantityType(.cyclingCadence),
                HKQuantityType(.activeEnergyBurned)
            ]
            if descriptor?.simulation?.saveToHealth == true {
                share.insert(HKQuantityType(.cyclingSpeed))
                share.insert(HKQuantityType(.distanceCycling))
            }
            try await store.requestAuthorization(toShare: share, read: [HKQuantityType(.heartRate)])
            if descriptor != nil, store.authorizationStatus(for: HKObjectType.workoutType()) != .sharingAuthorized {
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
            if descriptor != nil {
                let unavailable = [
                    (HKQuantityType(.cyclingPower), "power"),
                    (HKQuantityType(.cyclingCadence), "cadence"),
                    (HKQuantityType(.activeEnergyBurned), "energy")
                ].filter { store.authorizationStatus(for: $0.0) != .sharingAuthorized }.map(\.1)
                if !unavailable.isEmpty {
                    recordingError = "Health sharing is not enabled for \(unavailable.joined(separator: ", ")); the saved workout may omit these metrics."
                }
                if descriptor?.simulation?.saveToHealth == true,
                   (store.authorizationStatus(for: HKQuantityType(.cyclingSpeed)) != .sharingAuthorized ||
                    store.authorizationStatus(for: HKQuantityType(.distanceCycling)) != .sharingAuthorized) {
                    recordingError = [recordingError, "Simulated speed/distance sharing is not fully enabled in Health."].compactMap { $0 }.joined(separator: " ")
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
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            // Only measured KICKR power/cadence is added; no Watch estimates for these streams.
            builder.dataSource?.disableCollection(for: HKQuantityType(.cyclingPower))
            builder.dataSource?.disableCollection(for: HKQuantityType(.cyclingCadence))
            builder.dataSource?.disableCollection(for: HKQuantityType(.distanceCycling))
            builder.dataSource?.disableCollection(for: HKQuantityType(.cyclingSpeed))
            active = true
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
                status = "Measuring HR; diagnostic will be discarded."
            }
        } catch {
            let failure = startPhase.failure(error)
            status = failure
            UserDefaults.standard.set(failure, forKey: "lastSessionError")
            if let session {
                session.end()
                do { try await waitForState(.ended, session: session) }
                catch {
                    status += " Cleanup incomplete: \(error.localizedDescription). Use End locally before starting again."
                    linkStale = true
                    reportToPhone(status)
                    return
                }
            }
            builder?.discardWorkout()
            resetSession()
            reportToPhone(failure)
        }
    }

    private func waitForState(_ state: HKWorkoutSessionState, session: HKWorkoutSession) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while session.state != state {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  state == .ended || session.state != .ended else {
                throw NSError(domain: "CadenceCore.SessionLifecycle", code: state.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Watch session did not reach \(state == .prepared ? "prepared" : "ended") within 8 seconds (current state \(session.state.rawValue))."])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func reportToPhone(_ failure: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["failure": failure, "stagedID": staged?.id.uuidString ?? ""], replyHandler: nil) { error in
            Task { @MainActor in self.recordingError = "Error report delivery failed: \(error.localizedDescription)" }
        }
    }

    func control(_ action: RideAction) {
        guard active, !saving, let ride else { return }
        guard [.pause, .resume, .finish].contains(action) else { return }
        let message = RideMessage(rideID: ride.id, action: action)
        pendingCommand = message
        status = "Waiting for iPhone to confirm \(action.rawValue)…"
        Task {
            do { try await send(message) }
            catch {
                guard active, self.ride?.id == message.rideID, pendingCommand?.commandID == message.commandID else { return }
                status = "Control delivery failed: \(error.localizedDescription). Trainer state unconfirmed."
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
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                do {
                    if let pending = self.pendingCommand {
                        // Refresh transport age without changing command identity during retries.
                        try await self.send(RideMessage(rideID: ride.id, action: pending.action, commandID: pending.commandID))
                    } else {
                        try await self.send(RideMessage(rideID: ride.id, action: .heartbeat))
                    }
                } catch { self.status = "iPhone delivery failed: \(error.localizedDescription)" }
                if let last = self.lastSnapshotDate ?? self.connectionStart, Date().timeIntervalSince(last) > 8, !self.linkStale {
                    self.linkStale = true
                    if self.recordingRunning { self.session?.pause(); self.recordingRunning = false }
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
                    startingCollection = true
                    startPhase = .collecting
                    if let session {
                        session.end()
                        try await waitForState(.ended, session: session)
                    }
                    startingCollection = false
                    startPhase = .recording
                    builder?.discardWorkout()
                    resetSession()
                } else if recordingRunning { session?.pause(); recordingRunning = false }
                return
            }
            guard message.action == .snapshot, let update = message.snapshot,
                  let descriptor = ride, update.elapsed <= descriptor.duration else { throw RideLinkError.invalidMessage }
            guard update.sequence > lastSequence, let session, let builder else { return }
            guard update.simulation == nil || descriptor.simulation != nil,
                  (update.simulation?.distance ?? 0) >= (snapshot?.simulation?.distance ?? 0) else {
                throw RideLinkError.invalidMessage
            }
            lastSequence = update.sequence
            snapshot = update
            lastSnapshotDate = Date()
            linkStale = false
            if let pendingCommand {
                let confirmed: Bool
                switch pendingCommand.action {
                case .ready: confirmed = update.state != "ready"
                case .pause: confirmed = ["pausing", "paused", "interrupted"].contains(update.state)
                case .resume: confirmed = ["settingTarget", "starting", "running", "interrupted"].contains(update.state)
                case .finish: confirmed = ["finishing", "completed", "interrupted"].contains(update.state)
                default: confirmed = true
                }
                if confirmed { self.pendingCommand = nil }
            }
            status = update.status
            if update.state == "running", pendingCommand?.action != .pause {
                if collectionStart == nil {
                    let date = message.date
                    session.startActivity(with: date)
                    try await builder.beginCollection(at: date)
                    guard self.session === session, active else { return }
                    collectionStart = date
                    recordingRunning = true
                    if let ride {
                        try await builder.addMetadata([
                            HKMetadataKeyExternalUUID: ride.id.uuidString,
                            HKMetadataKeyWorkoutBrandName: "CadenceCore",
                            "CadenceCoreWorkoutName": ride.name,
                            "CadenceCoreFTP": ride.ftp,
                            "CadenceCoreTrainerMetrics": "Measured FTMS power and cadence"
                        ])
                        if let model = ride.simulation, model.saveToHealth {
                            try await builder.addMetadata([
                                "CadenceCoreSimulationModel": "Flat-road steady-state v\(model.version)",
                                "CadenceCoreSimulationParameters": String(decoding: JSONEncoder().encode(model), as: UTF8.self),
                                "CadenceCoreDistanceProvenance": "Simulated from measured FTMS power; aggregate active fresh-telemetry distance. No GPS."
                            ])
                        }
                    }
                } else if !recordingRunning {
                    session.resume()
                    recordingRunning = true
                }
                guard self.session === session, active else { return }
            } else if collectionStart != nil, ["pausing", "paused", "finishing", "interrupted"].contains(update.state),
                      recordingRunning {
                session.pause()
                recordingRunning = false
            }
            if let start = collectionStart, let window = samples.take(update, now: Date(), collectionStart: start),
               recordingRunning {
                var quantities: [HKQuantitySample] = []
                if let watts = update.power, watts >= 0,
                   store.authorizationStatus(for: HKQuantityType(.cyclingPower)) == .sharingAuthorized {
                    quantities.append(HKQuantitySample(type: HKQuantityType(.cyclingPower),
                        quantity: HKQuantity(unit: .watt(), doubleValue: Double(watts)),
                        start: window.start, end: window.end))
                }
                if let cadence = update.cadence,
                   store.authorizationStatus(for: HKQuantityType(.cyclingCadence)) == .sharingAuthorized {
                    quantities.append(HKQuantitySample(type: HKQuantityType(.cyclingCadence),
                        quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: cadence),
                        start: window.start, end: window.end))
                }
                if descriptor.simulation?.saveToHealth == true,
                   let simulated = update.simulation, let speed = simulated.speed,
                   let date = simulated.date, abs(date.timeIntervalSince(window.end)) <= 0.1,
                   store.authorizationStatus(for: HKQuantityType(.cyclingSpeed)) == .sharingAuthorized {
                    quantities.append(HKQuantitySample(type: HKQuantityType(.cyclingSpeed),
                        quantity: HKQuantity(unit: HKUnit.meter().unitDivided(by: .second()), doubleValue: speed),
                        start: window.start, end: window.end,
                        metadata: ["CadenceCoreSimulated": true]))
                }
                if !quantities.isEmpty {
                    do { try await builder.addSamples(quantities) }
                    catch { recordingError = "Trainer/simulated metrics were not recorded: \(error.localizedDescription)" }
                }
            }
            if update.state == "completed" { await finishRecording(confirmedTrainerStop: true) }
        } catch {
            recordingError = startingCollection ? WatchStartPhase.collecting.failure(error) :
                "Workout communication/recording failed: \(error.localizedDescription) [\((error as NSError).domain):\((error as NSError).code)]"
            if startingCollection {
                UserDefaults.standard.set(recordingError, forKey: "lastSessionError")
                reportToPhone(recordingError ?? "Health recording failed.")
            }
            if recordingRunning { session?.pause(); recordingRunning = false }
            if let ride {
                do { try await send(RideMessage(rideID: ride.id, action: .failure, detail: recordingError)) }
                catch { status = "Failure delivery failed: \(error.localizedDescription)" }
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
                do { try await waitForState(.ended, session: session) }
                catch { status = "Diagnostic end unconfirmed: \(error.localizedDescription)"; return }
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
            await finishRecording(confirmedTrainerStop: false)
        }
    }

    private func finishRecording(confirmedTrainerStop: Bool) async {
        guard !finishing, let ride, let builder, let session else { return }
        finishing = true
        saving = true
        heartbeat?.cancel()
        pendingCommand = nil
        let end = Date()
        session.end()
        do {
            try await waitForState(.ended, session: session)
            if collectionStart != nil {
                try await builder.addMetadata(["CadenceCoreTrainerStopConfirmed": confirmedTrainerStop])
                if let start = collectionStart, ride.simulation?.saveToHealth == true,
                   let distance = snapshot?.simulation?.distance,
                   store.authorizationStatus(for: HKQuantityType(.distanceCycling)) == .sharingAuthorized {
                    // One aggregate sample preserves the iPhone total even when mirrored speed packets are lost.
                    do {
                        try await builder.addSamples([HKQuantitySample(type: HKQuantityType(.distanceCycling),
                            quantity: HKQuantity(unit: .meter(), doubleValue: distance), start: start, end: end,
                            metadata: ["CadenceCoreSimulated": true, "CadenceCoreAggregateDistance": true])])
                    } catch {
                        recordingError = "Simulated distance was not recorded: \(error.localizedDescription)"
                    }
                }
                try await builder.endCollection(at: end)
                guard let saved = try await builder.finishWorkout() else {
                    throw RideLinkError.noSavedWorkout
                }
                status = "Saved to Health."
                if !confirmedTrainerStop { status += " Trainer stop was NOT confirmed." }
                if recordingError != nil { status += " Some metrics were not recorded; see the warning." }
                if let distance = snapshot?.simulation?.distance, ride.simulation?.saveToHealth == true {
                    status += " \((distance / 1000).formatted(.number.precision(.fractionLength(2)))) km simulated (Health inclusion depends on permission/save result)."
                }
                UserDefaults.standard.set(status, forKey: "lastHealthSaveStatus")
                deliverReceipt(RideMessage(rideID: ride.id, action: .saved,
                    detail: "\(status) Health workout \(saved.uuid.uuidString)."))
            } else {
                builder.discardWorkout()
                status = "Ended before recording started. No workout saved."
                deliverReceipt(RideMessage(rideID: ride.id, action: .saved, detail: status))
            }
            staged = nil
        } catch {
            if session.state != .ended {
                finishing = false
                saving = false
                linkStale = true
                status = "Watch session has not ended: \(error.localizedDescription). Retry End locally; trainer stop is unconfirmed."
                recordingError = status
                return
            }
            recordingError = "Health save failed: \(error.localizedDescription). No automatic retry to avoid duplicate saves."
            status = "Workout ended; save is unconfirmed."
            UserDefaults.standard.set("\(status) \(recordingError ?? "")", forKey: "lastHealthSaveStatus")
            deliverReceipt(RideMessage(rideID: ride.id, action: .failure, detail: recordingError))
        }
        resetSession()
        saving = false
    }

    private func deliverReceipt(_ message: RideMessage) {
        do {
            WCSession.default.transferUserInfo(["receipt": try JSONEncoder().encode(message)])
        } catch { recordingError = "Could not queue Health save result to iPhone: \(error.localizedDescription)" }
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

    private func acceptStage(_ context: [String: Any]) {
        guard !active, !starting, !saving else {
            status = "A workout is active. Finish it before loading another."
            return
        }
        guard let data = context["stage"] as? Data else { staged = nil; return }
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
            Task { @MainActor in self.status = "Workout loaded; iPhone acknowledgment failed: \(error.localizedDescription)" }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in acknowledgeStage() }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["stage"] as? Data
        Task { @MainActor in
            if let error { status = "Watch connection activation failed: \(error.localizedDescription)"; return }
            acceptStage(data.map { ["stage": $0] } ?? [:])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Decode the Sendable descriptor before crossing the actor boundary.
        let data = applicationContext["stage"] as? Data
        Task { @MainActor in acceptStage(data.map { ["stage": $0] } ?? [:]) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
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
            if ride == nil { endDiagnostic() }
            else {
                linkStale = true
                status = "Watch session ended unexpectedly. Trainer stop is unconfirmed; end locally to save."
                if let ride {
                    do { try await send(RideMessage(rideID: ride.id, action: .failure, detail: status)) }
                    catch { status += " iPhone notification failed: \(error.localizedDescription)" }
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
                do { try await send(RideMessage(rideID: ride.id, action: .failure, detail: status)) }
                catch { status += " iPhone notification failed: \(error.localizedDescription)" }
            } else { endDiagnostic(); status = "Diagnostic failed: \(error.localizedDescription)" }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
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

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in
            guard session === workoutSession, !finishing else { return }
            linkStale = true
            mirrorDisconnected = true
            if recordingRunning { session?.pause(); recordingRunning = false }
            status = "iPhone mirroring disconnected: \(error?.localizedDescription ?? "Connection ended"). Trainer state unconfirmed."
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            guard active, builder === workoutBuilder, collectedTypes.contains(HKQuantityType(.heartRate)),
                  let statistics = workoutBuilder.statistics(for: HKQuantityType(.heartRate)),
                  let quantity = statistics.mostRecentQuantity(),
                  let interval = statistics.mostRecentQuantityDateInterval() else { return }
            let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            heartRate = bpm
            sampleDate = interval.end
            do { try await send(RideMessage(rideID: ride?.id, action: .heartRate, date: interval.end, bpm: bpm)) }
            catch {
                guard active, builder === workoutBuilder else { return }
                status = "HR measured locally; iPhone delivery failed: \(error.localizedDescription)"
            }
        }
    }
}
