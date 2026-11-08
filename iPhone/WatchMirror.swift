import HealthKit
import Observation
import WatchConnectivity

@MainActor @Observable
final class WatchMirror: NSObject, HKWorkoutSessionDelegate, WCSessionDelegate {
    var heartRate: Double?
    var receivedAt: Date?
    private(set) var recordingMetrics: RecordingMetrics?
    var status = "Prepare Watch connection, then send a workout to Watch."
    private(set) var staged: RideDescriptor?
    private(set) var coordinatedID: UUID?
    private var coordinatedPlaybackID: UUID?
    var isWatchRide: Bool {
        trainer.recoveredWatchRide
            || (coordinatedPlaybackID != nil && coordinatedPlaybackID == trainer.playbackID)
    }
    private let store = HKHealthStore()
    private let trainer: TrainerDiagnostic
    private var session: HKWorkoutSession?
    private var stagedWorkout: Workout?
    private var gate: RideCommandGate?
    private var lastContact: Date?
    private var sequence = 0
    private var sending = false
    private var lastSent: Date?
    private var lastState: String?
    private var acknowledgedCommandID: UUID?
    private var pendingCadenceHaptic: (guidance: CadenceGuidanceEvaluator.Result, date: Date)?
    private var watchdog: Task<Void, Never>?
    private var prepared = false
    private(set) var staging = false
    private(set) var watchReachable = false
    private(set) var stageDelivered = false

    init(trainer: TrainerDiagnostic) {
        self.trainer = trainer
        super.init()
        if UserDefaults.standard.string(forKey: "lastHealthReceiptID") != nil {
            status = UserDefaults.standard.string(forKey: "lastHealthReceiptStatus") ?? status
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        trainer.onWorkoutUpdate = { [weak self] in
            self?.trainer.captureRide()
            self?.publish()
        }
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in
                guard let self else { return }
                guard self.session == nil || self.session?.state == .ended else {
                    self.status = "Another Watch session is already mirrored."
                    return
                }
                self.session = session
                session.delegate = self
                self.status = "Watch session connected."
            }
        }
    }

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
            prepared = true
            status = "Ready. Send a workout to Watch or start a Watch HR diagnostic."
        } catch {
            status = "Health setup failed: \(error.localizedDescription)"
        }
    }

    func stage(_ workout: Workout, ftp: Double) async {
        guard !staging else { return }
        staging = true
        defer { staging = false }
        guard !trainer.workoutOwnsTrainer, !trainer.sequenceActive, coordinatedID == nil,
            session == nil
        else {
            status = "Finish the current ride or Watch diagnostic before staging another workout."
            return
        }
        guard await trainer.prepareForRide() else {
            status = trainer.preparationError ?? "Trainer preparation failed."
            return
        }
        if !prepared { await prepare() }
        guard prepared else { return }
        do {
            guard !trainer.workoutOwnsTrainer, !trainer.sequenceActive, coordinatedID == nil,
                session == nil, trainer.readyToRide, let range = trainer.powerRange
            else {
                status = "Trainer readiness changed. Prepare the trainer here and retry."
                return
            }
            _ = try WorkoutPlayback(workout: workout, ftp: ftp, range: range)
            let descriptor = RideDescriptor(
                id: UUID(), name: workout.name, duration: workout.duration,
                ftp: ftp, simulation: trainer.simulationSettings,
                cadenceConfiguration: trainer.configuration.cadence.snapshot())
            guard descriptor.isValid else { throw RideLinkError.invalidMessage }
            guard WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled
            else {
                status = "Watch connection is not ready. Install/open CadenceCore on the paired Watch."
                return
            }
            let data = try JSONEncoder().encode(descriptor)
            try WCSession.default.updateApplicationContext(["stage": data])
            staged = descriptor
            stagedWorkout = workout
            stageDelivered = false
            status = "Workout queued. Open CadenceCore on Watch; waiting for delivery confirmation."
        } catch {
            status = "Could not stage workout: \(error.localizedDescription)"
        }
    }

    private func receive(_ packet: Data) {
        do {
            let message = try RideMessage.decode(packet)
            if [.heartbeat, .heartRate].contains(message.action),
                let recording = message.recording, message.rideID == coordinatedID, coordinatedID != nil
            {
                recordingMetrics = recording
                trainer.recordWatchMetrics(summary: recording)
            }
            if message.action == .heartRate {
                guard message.rideID == coordinatedID else { throw RideLinkError.invalidMessage }
                heartRate = message.bpm
                receivedAt = message.date
                trainer.recordWatchMetrics(
                    heartRate: message.bpm, date: message.date, summary: message.recording)
                return
            }
            if message.action == .ready {
                acknowledgedCommandID = message.commandID
                if trainer.recoveredWatchRide, trainer.playbackID == message.rideID,
                    trainer.playback?.state == .interrupted, let id = message.rideID,
                    let archive = trainer.archiveStore.ride(id: id), coordinatedID == nil
                {
                    coordinatedID = id
                    coordinatedPlaybackID = id
                    gate = RideCommandGate(rideID: id)
                    lastContact = Date()
                    sequence = 0
                    lastSent = nil
                    lastState = nil
                    staged = RideDescriptor(
                        id: id, name: archive.workout.name, duration: archive.workout.duration,
                        ftp: archive.ftp, simulation: archive.simulation,
                        cadenceConfiguration: archive.cadenceConfiguration)
                    stagedWorkout = archive.workout
                    if let distance = message.snapshot?.simulation?.distance {
                        trainer.reconcileRecoveredDistance(distance)
                    }
                    trainer.resumeWorkout()
                    monitorLink()
                    publish(force: true)
                    status = "Recovered ride reconnected to the existing Watch recording."
                    return
                }
                if coordinatedID != nil, coordinatedID == message.rideID {
                    lastContact = Date()
                    publish(force: true)
                    return
                }
                guard let staged, message.rideID == staged.id, let stagedWorkout,
                    coordinatedID == nil, !trainer.workoutOwnsTrainer, !trainer.sequenceActive
                else {
                    sendFailure(
                        to: message.rideID, detail: "Workout is no longer staged or the trainer is busy.")
                    return
                }
                coordinatedID = staged.id
                gate = RideCommandGate(rideID: staged.id)
                lastContact = Date()
                sequence = 0
                recordingMetrics = nil
                lastSent = nil
                lastState = nil
                trainer.startWorkout(
                    stagedWorkout, ftp: staged.ftp, simulation: staged.simulation,
                    cadence: staged.cadenceConfiguration, id: staged.id, recordingMode: .watch)
                if trainer.playbackID != staged.id || !trainer.workoutOwnsTrainer {
                    sendFailure(to: staged.id, detail: trainer.playbackStatus)
                    coordinatedID = nil
                    return
                }
                coordinatedPlaybackID = trainer.playbackID
                status = "Watch workout connected. Trainer owns interval execution."
                monitorLink()
                publish(force: true)
                return
            }
            guard message.rideID == coordinatedID, coordinatedID != nil else {
                throw RideLinkError.invalidMessage
            }
            lastContact = Date()
            switch message.action {
            case .heartbeat: publish(force: true)
            case .pause, .resume, .finish, .intensity:
                guard gate?.accept(message) == true else {
                    publish(force: true)
                    return
                }
                acknowledgedCommandID = message.commandID
                switch message.action {
                case .pause: trainer.pauseWorkout()
                case .resume: trainer.resumeWorkout()
                case .finish: trainer.finishWorkout()
                case .intensity:
                    if let intensity = message.requestedIntensity { trainer.adjustIntensity(intensity) }
                default: break
                }
                publish(force: true)
            case .failure:
                status = message.detail ?? "Watch workout failed."
                trainer.interruptCoordinatedWorkout(status)
            default: throw RideLinkError.invalidMessage
            }
        } catch {
            status = "Watch communication rejected: \(error.localizedDescription)"
        }
    }

    private func publish(force: Bool = false) {
        if let pendingCadenceHaptic,
            trainer.cadenceGuidance?.status != pendingCadenceHaptic.guidance.status
                || trainer.cadenceGuidance?.target != pendingCadenceHaptic.guidance.target
        {
            self.pendingCadenceHaptic = nil
        }
        if pendingCadenceHaptic == nil, let guidance = trainer.cadenceGuidance, guidance.recommendsHaptic {
            pendingCadenceHaptic = (guidance, Date())
        }
        guard let id = coordinatedID, trainer.playbackID == id,
            let session, let playback = trainer.playback, !sending
        else {
            return
        }
        let stateChanged = playback.state.rawValue != lastState
        if playback.state != .running || pendingCadenceHaptic.map({ Date().timeIntervalSince($0.date) > 3 }) == true {
            pendingCadenceHaptic = nil
        }
        guard force || stateChanged || pendingCadenceHaptic != nil || lastSent.map({ Date().timeIntervalSince($0) >= 1 }) ?? true
        else { return }
        sequence += 1
        let fresh = trainer.telemetryDate.map { Date().timeIntervalSince($0) <= 3 } ?? false
        let snapshot = RideSnapshot(
            sequence: sequence, state: playback.state.rawValue, elapsed: playback.elapsed,
            interval: playback.position.map { $0.index + 1 }, remaining: playback.position?.remaining,
            target: playback.position?.targetWatts, power: fresh ? trainer.power : nil,
            cadence: fresh ? trainer.cadence : nil, telemetryDate: fresh ? trainer.telemetryDate : nil,
            status: [trainer.playbackStatus, trainer.simulationError].compactMap { $0 }.joined(
                separator: " "),
            simulation: trainer.simulation?.metrics, intensity: playback.intensity,
            guidance: pendingCadenceHaptic?.guidance ?? trainer.cadenceGuidance, cue: trainer.activeCue,
            acknowledgedCommandID: acknowledgedCommandID
        )
        sending = true
        lastSent = Date()
        lastState = playback.state.rawValue
        Task {
            defer { sending = false }
            do {
                try await session.sendToRemoteWorkoutSession(
                    data: JSONEncoder().encode(RideMessage(rideID: id, action: .snapshot, snapshot: snapshot))
                )
                pendingCadenceHaptic = nil
                acknowledgedCommandID = nil
            } catch {
                if coordinatedID == id { status = "Watch update failed: \(error.localizedDescription)" }
            }
        }
    }

    private func sendFailure(to id: UUID?, detail: String) {
        guard let session else {
            status = detail
            return
        }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(
                    data: JSONEncoder().encode(RideMessage(rideID: id, action: .failure, detail: detail))
                )
            } catch { status = "\(detail) Watch delivery failed: \(error.localizedDescription)" }
        }
    }

    private func monitorLink() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while let self, self.coordinatedID != nil {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if self.lastContact.map({ Date().timeIntervalSince($0) > 8 }) ?? true {
                    self.status =
                        "Watch connection stale. Workout frozen; reduced load requested. Resume explicitly after reconnecting."
                    self.trainer.interruptCoordinatedWorkout(self.status)
                }
            }
        }
    }

    private func clearCoordination() {
        watchdog?.cancel()
        pendingCadenceHaptic = nil
        coordinatedID = nil
        staged = nil
        stagedWorkout = nil
        gate = nil
        stageDelivered = false
        heartRate = nil
        receivedAt = nil
        do { try WCSession.default.updateApplicationContext([:]) } catch {
            status += " Could not clear staged Watch workout: \(error.localizedDescription)"
        }
    }

    func releaseFinishedCoordination() {
        guard trainer.playback?.state == .completed else {
            status = "Finish the trainer workout before releasing Watch coordination."
            return
        }
        clearCoordination()
        status =
            "Watch coordination released. Any Watch recording still active must be ended on Watch; Health save is not confirmed."
    }

    func resumeRide() {
        if isWatchRide {
            guard coordinatedID != nil, session != nil,
                lastContact.map({ Date().timeIntervalSince($0) <= 8 }) == true
            else {
                status =
                    "Resume blocked: Watch recording/connection is unavailable. Finish this ride and end/save locally on Watch if needed."
                return
            }
        }
        trainer.resumeWorkout()
    }

    private func receiveReceipt(_ data: Data) {
        do {
            let receipt = try RideMessage.decode(data, allowDelayedReceipt: true)
            guard let id = receipt.rideID,
                id == coordinatedID || trainer.archiveStore.ride(id: id) != nil,
                [.saved, .failure].contains(receipt.action)
            else {
                throw RideLinkError.invalidMessage
            }
            if receipt.action == .failure, trainer.archiveStore.ride(id: id)?.healthReceipt.status == .saved { return }
            if trainer.workoutOwnsTrainer, trainer.playbackID == id {
                trainer.interruptCoordinatedWorkout(
                    "Watch recording ended. Requesting reduced load; trainer finish was not confirmed.")
            }
            let detail =
                receipt.detail ?? (receipt.action == .saved ? "Saved to Health." : "Health save failed.")
            if trainer.playbackID == id || coordinatedID == id {
                status = detail
                if let recording = receipt.recording { recordingMetrics = recording }
            }
            if trainer.archiveStore.ride(id: id) != nil {
                try trainer.recordHealthReceipt(receipt)
            }
            UserDefaults.standard.set(id.uuidString, forKey: "lastHealthReceiptID")
            UserDefaults.standard.set(detail, forKey: "lastHealthReceiptStatus")
            if coordinatedID == id { clearCoordination() }
        } catch { status = "Health save receipt rejected: \(error.localizedDescription)" }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            if toState == .ended {
                heartRate = nil
                receivedAt = nil
                session = nil
                if coordinatedID != nil, trainer.playback?.state != .completed {
                    trainer.interruptCoordinatedWorkout(
                        "Watch session ended before trainer finish was confirmed.")
                }
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            status = "Watch session failed: \(error.localizedDescription)"
            trainer.recordWatchFailure(status)
            trainer.interruptCoordinatedWorkout(status)
            session = nil
            heartRate = nil
            receivedAt = nil
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            for packet in data { receive(packet) }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            session = nil
            heartRate = nil
            receivedAt = nil
            if coordinatedID != nil, trainer.playback?.state != .completed {
                status =
                    "Watch mirroring disconnected: \(error?.localizedDescription ?? "Connection ended")."
                trainer.interruptCoordinatedWorkout(status)
            } else if coordinatedID != nil {
                status = "Watch session ended. Waiting for Health save result."
            } else if !isWatchRide {
                status = "Watch diagnostic ended."
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo["receipt"] as? Data else { return }
        Task { @MainActor in receiveReceipt(data) }
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in
            watchReachable = reachable
            if let error { status = "Watch connection activation failed: \(error.localizedDescription)" }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in watchReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let id = (message["stagedID"] as? String).flatMap(UUID.init(uuidString:))
        let failure = message["failure"] as? String
        Task { @MainActor in
            guard let id, staged?.id == id else { return }
            if let failure {
                status = failure
                UserDefaults.standard.set(failure, forKey: "lastWatchSessionError")
                trainer.recordWatchFailure(failure)
                return
            }
            stageDelivered = true
            status = "Ready on Watch. Tap Start workout on your wrist."
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
