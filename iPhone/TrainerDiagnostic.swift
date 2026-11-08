import CoreBluetooth
import Foundation
import Observation

@MainActor @Observable
// Both central and peripheral delegates are delivered on the explicitly selected main queue.
final class TrainerDiagnostic: NSObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate
{
    struct Device: Identifiable {
        let id: UUID
        let name: String
        let peripheral: CBPeripheral
    }

    var devices: [Device] = []
    var status = "Bluetooth has not been requested."
    var services: [String] = []
    var events: [String] = []
    var power: Int?
    var cadence: Double?
    var telemetryDate: Date?
    var connected = false
    var hasControl = false
    var powerSupported = false
    var powerRange: PowerRange?
    var pending = false
    var diagnosticFile: URL?
    var persistenceError: String?
    var sequenceActive = false
    var trainerRunning = false
    var testLength: DiagnosticSchedule.Length = .short
    private(set) var stopFlow = ReducedLoadStop()
    private(set) var stopStatus = "Reduced-load stop has not been requested."
    private(set) var playback: WorkoutPlayback?
    private(set) var playbackID: UUID?
    private(set) var playbackStatus = "No workout selected."
    var onWorkoutUpdate: (() -> Void)?
    let configuration: RideConfiguration
    let archiveStore: RideArchiveStore
    private var currentArchive: RideArchive?
    private var archiveLastWrite: Double?
    private(set) var archiveError: String?
    private var receivedHeartRate: (value: Double, date: Date)?
    private var archivedHeartRateDate: Date?
    private var recordingMetrics: RecordingMetrics?
    private(set) var recoveredWatchRide = false
    var simulationSettings: SimulationConfiguration? { configuration.simulation }
    private(set) var simulation: RideSimulation?
    var simulationError: String? { configuration.simulationError ?? simulationRuntimeError }
    private var simulationRuntimeError: String?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlPoint: CBCharacteristic?
    private var controlSubscribed = false
    private var pendingOpcode: UInt8?
    private var timeout: Task<Void, Never>?
    private let formatter = ISO8601DateFormatter()
    private var sequenceStart: TimeInterval?
    private var sequenceTarget: Int?
    private var activeTestLength: DiagnosticSchedule.Length = .short
    private var lastSequenceSampleTime: TimeInterval?
    private var lastWorkoutLogTime: Double?
    private var workoutWatchdog: Task<Void, Never>?
    private(set) var preparing = false
    private(set) var preparationError: String?
    private var reconnectPreferred = false
    private var connectionTimeout: Task<Void, Never>?
    private(set) var scanning = false
    private var scanTimeout: Task<Void, Never>?
    private var preparationCancelled = false
    private var cadenceEvaluator: CadenceGuidanceEvaluator?
    private(set) var cadenceGuidance: CadenceGuidanceEvaluator.Result?
    private var cadenceSampleUptime: Double?
    private(set) var activeCue: String?

    var isConnecting: Bool { peripheral != nil && !connected }
    var selectedTrainerName: String? {
        peripheral?.name ?? UserDefaults.standard.string(forKey: "trainerName")
    }
    var readinessIssue: TrainerReadiness.Issue? {
        TrainerReadiness.issue(
            connected: connected,
            capabilitiesReady: controlSubscribed && powerSupported && powerRange != nil,
            hasControl: hasControl, busy: pending || stopFlow.isInProgress, sampleDate: telemetryDate)
    }
    var readyToRide: Bool { readinessIssue == nil }

    func findTrainer() {
        reconnectPreferred = true
        scan()
    }

    func prepareForRide(forResume: Bool = false) async -> Bool {
        guard !preparing else { return false }
        let resumable = playback.map { [.paused, .interrupted].contains($0.state) } ?? false
        guard !sequenceActive, !workoutOwnsTrainer || (forResume && resumable) else {
            preparationError = "Finish the current ride or diagnostic before preparing a new one."
            return false
        }
        preparing = true
        preparationCancelled = false
        preparationError = nil
        defer { preparing = false }
        if !connected, !isConnecting { findTrainer() }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var requested = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if preparationCancelled { return false }
            if readyToRide { return true }
            if canRequestControl, !hasControl, !requested {
                requested = true
                requestControl()
            }
            if requested, !pending, !hasControl {
                preparationError = "Trainer did not grant control. Close Zwift/Wahoo and retry."
                return false
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch {
                preparationError = "Ride preparation cancelled."
                return false
            }
        }
        preparationError =
            "Trainer is not ready: \(readinessIssue?.rawValue ?? status). Choose a trainer below, close other cycling apps, and pedal briefly for fresh measurements."
        record(preparationError ?? "Trainer preparation timed out.")
        return false
    }

    var workoutOwnsTrainer: Bool {
        playback.map { $0.state != .completed } ?? false
    }

    func saveSimulationSettings(_ settings: SimulationConfiguration?) {
        configuration.saveSimulation(settings)
        if configuration.simulationError == nil { simulationRuntimeError = nil }
        if let error = configuration.simulationError { record(error) }
    }

    func recordWatchFailure(_ message: String) {
        record("Watch session: \(message)")
    }

    func startWorkout(
        _ workout: Workout, ftp: Double, simulation configuration: SimulationConfiguration? = nil,
        cadence policy: CadenceConfiguration? = nil, id: UUID = UUID(),
        recordingMode: RideArchive.RecordingMode = .iPhone
    ) {
        if let archiveError {
            playbackStatus = "Start blocked. Retry the previous local ride save first: \(archiveError)"
            record(playbackStatus)
            return
        }
        defer { onWorkoutUpdate?() }
        guard !workoutOwnsTrainer, !sequenceActive, readyToRide, let range = powerRange else {
            playbackStatus =
                "Prepare the trainer on the workout setup screen, with fresh telemetry and no active test."
            record(playbackStatus)
            return
        }
        do {
            let engine = try WorkoutPlayback(workout: workout, ftp: ftp, range: range)
            let model = try configuration.map { try RideSimulation(configuration: $0) }
            cadenceEvaluator = try CadenceGuidanceEvaluator(
                configuration: policy ?? self.configuration.cadence.snapshot())
            cadenceGuidance = nil
            activeCue = nil
            var archive = try RideArchive(
                id: id, workout: workout, ftp: ftp, simulation: configuration,
                trainer: RideTrainerIdentity(
                    id: peripheral?.identifier, name: selectedTrainerName ?? "Selected trainer"),
                startedAt: Date(), recordingMode: recordingMode,
                cadenceConfiguration: policy ?? self.configuration.cadence.snapshot(), initialIntensity: 1)
            try archive.append(
                event: RideArchiveEvent(state: .paused, date: archive.startedAt, activeElapsed: 0))
            if recordingMode == .iPhone {
                try archive.setHealthReceipt(
                    RideHealthReceipt(
                        status: .unavailable,
                        detail: "iPhone-only ride; no Health workout was created."))
            }
            try archiveStore.save(archive)
            currentArchive = archive
            archiveError = nil
            recoveredWatchRide = false
            archiveLastWrite = ProcessInfo.processInfo.systemUptime
            receivedHeartRate = nil
            archivedHeartRateDate = nil
            recordingMetrics = nil
            playback = engine
            simulation = model
            simulationRuntimeError = nil
            playbackID = id
            lastWorkoutLogTime = nil
            playbackStatus = "Setting initial target…"
            record("Workout \(workout.name) starting with FTP snapshot \(ftp) W.")
            if let command = playback?.begin() { perform(command) }
        } catch {
            playbackStatus = error.localizedDescription
            record(playbackStatus)
        }
    }

    func pauseWorkout() {
        defer { onWorkoutUpdate?() }
        simulation?.suspend()
        clearCadenceGuidance()
        if let command = playback?.pause(now: ProcessInfo.processInfo.systemUptime) { perform(command) }
    }

    func resumeWorkout() {
        defer { onWorkoutUpdate?() }
        guard readyToRide else {
            playbackStatus = "Resume blocked: reacquire control and wait for fresh telemetry."
            record(playbackStatus)
            return
        }
        guard let snapshot = playback, let range = powerRange,
            range.minimum == snapshot.range.minimum,
            range.maximum == snapshot.range.maximum,
            range.increment == snapshot.range.increment
        else {
            playbackStatus =
                "Resume blocked: trainer power range changed. Finish this workout before starting a new one."
            record(playbackStatus)
            return
        }
        if let command = playback?.begin() {
            simulation?.suspend()
            perform(command)
        }
    }

    func finishWorkout() {
        defer { onWorkoutUpdate?() }
        simulation?.suspend()
        cadenceGuidance = nil
        activeCue = nil
        if let command = playback?.finish(now: ProcessInfo.processInfo.systemUptime) {
            perform(command)
        }
    }

    func adjustIntensity(_ value: Double) {
        defer { onWorkoutUpdate?() }
        do {
            if let command = try playback?.adjustIntensity(
                value, commandPending: pending || stopFlow.isInProgress)
            {
                perform(command)
            }
            playbackStatus = "Intensity \(Int((value * 100).rounded()))%. FTP remains unchanged."
        } catch {
            playbackStatus = "Intensity unchanged: \(error.localizedDescription)"
            record(playbackStatus)
        }
    }

    func interruptCoordinatedWorkout(_ reason: String) {
        guard workoutOwnsTrainer, playback?.state != .interrupted else { return }
        interruptWorkout(reason)
        stopTrainer()
    }

    private func perform(_ command: WorkoutPlayback.Command) {
        switch command {
        case .target(let watts):
            stopFlow = ReducedLoadStop()
            stopStatus = "Workout target active; reduced-load stop has not been requested."
            playbackStatus = "Sending workout target \(watts) W…"
            send(FTMS.targetPower(Int16(watts)))
        case .start:
            playbackStatus = "Starting trainer…"
            send(Data([7]))
        case .reducedLoadStop:
            playbackStatus = [playback?.error, "Requesting reduced load…"].compactMap { $0 }.joined(
                separator: " ")
            stopTrainer()
        }
    }

    private func clearCadenceGuidance() {
        _ = cadenceEvaluator?.evaluate(
            now: ProcessInfo.processInfo.systemUptime, active: false,
            intervalIndex: 0, targetWatts: 0, ftp: 1, cadence: nil, sampleTimestamp: nil)
        cadenceGuidance = nil
        activeCue = nil
    }

    private func interruptWorkout(_ reason: String) {
        guard workoutOwnsTrainer else { return }
        playback?.interrupt(reason)
        clearCadenceGuidance()
        simulation?.suspend()
        workoutWatchdog?.cancel()
        playbackStatus = reason
        record("Workout interrupted: \(reason)")
        onWorkoutUpdate?()
    }

    private func serviceWorkout(telemetrySample: Bool = false) {
        guard playback?.state == .running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let command = playback?.service(now: now, commandPending: pending)
        if telemetrySample, let playback, [.running, .finishing].contains(playback.state),
            let date = telemetryDate
        {
            do {
                try simulation?.sample(watts: power, uptime: now, activeTime: playback.elapsed, date: date)
            } catch {
                simulation?.suspend()
                simulationRuntimeError = "Simulation interrupted: \(error.localizedDescription)"
                record(simulationError ?? error.localizedDescription)
            }
        }
        if playback?.state != .running { simulation?.suspend() }
        if telemetrySample { cadenceSampleUptime = now }
        if let playback, let position = playback.position {
            cadenceGuidance = cadenceEvaluator?.evaluate(
                now: now, active: playback.state == .running,
                connected: connected && hasControl, intervalIndex: position.index,
                targetWatts: Double(position.targetWatts), ftp: playback.ftp,
                explicitCadence: position.cadence, cadence: cadence, sampleTimestamp: cadenceSampleUptime)
            activeCue =
                playback.state == .running
                ? playback.workout.cues?.last(where: {
                    playback.elapsed >= $0.offset && playback.elapsed < $0.offset + $0.duration
                })?.message : nil
        }
        if let error = playback?.error { record("Workout interrupted: \(error)") }
        if lastWorkoutLogTime.map({ now - $0 >= 15 }) ?? true {
            lastWorkoutLogTime = now
            record(
                "Workout elapsed \(playback?.elapsed ?? 0) s, measured \(power.map { "\($0) W" } ?? "unavailable"), cadence \(cadence.map { "\($0) rpm" } ?? "unavailable")."
            )
        }
        captureRide(telemetrySample: telemetrySample)
        if let command { perform(command) }
        onWorkoutUpdate?()
    }

    private func monitorWorkoutTelemetry() {
        workoutWatchdog?.cancel()
        workoutWatchdog = Task { [weak self] in
            while let self, self.playback?.state == .running {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard self.playback?.state == .running else { return }
                if self.telemetryDate.map({ Date().timeIntervalSince($0) > 3 }) ?? true {
                    self.serviceWorkout()
                }
            }
        }
    }

    init(configuration: RideConfiguration, archiveStore: RideArchiveStore) {
        self.configuration = configuration
        self.archiveStore = archiveStore
        super.init()
        archiveStore.onDelete = { [weak self] id in
            guard self?.currentArchive?.id == id else { return }
            self?.currentArchive = nil
            self?.archiveError = nil
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let url = directory.appendingPathComponent("trainer-diagnostic.txt")
            if FileManager.default.fileExists(atPath: url.path) {
                events = Array(
                    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
                        .suffix(500))
                diagnosticFile = url
            }
        } catch {
            persistenceError = "Cannot restore diagnostic log: \(error.localizedDescription)"
        }
    }
    func captureRide(telemetrySample: Bool = false) {
        guard var archive = currentArchive, archive.endedAt == nil, let playback else { return }
        let now = Date()
        var stateChanged = false
        do {
            if telemetrySample, [.running, .finishing].contains(playback.state),
                let date = telemetryDate, date >= archive.startedAt,
                archive.samples.last.map({ date.timeIntervalSince($0.date) >= 1 })
                    ?? (playback.elapsed >= 1)
            {
                let hr = receivedHeartRate.flatMap {
                    (0...3).contains(date.timeIntervalSince($0.date)) && $0.date != archivedHeartRateDate
                        ? $0 : nil
                }
                let simulated = simulation?.metrics
                let sample = RideArchiveSample(
                    date: date, activeElapsed: playback.elapsed,
                    power: power, cadence: cadence, heartRate: hr?.value,
                    target: playback.position?.targetWatts,
                    interval: playback.position.map { $0.index + 1 }, intensity: playback.intensity,
                    simulatedSpeed: simulated?.speed, simulatedDistance: simulated?.distance,
                    heartRateSampleDate: hr?.date)
                try archive.append(sample: sample)
                if let hr { archivedHeartRateDate = hr.date }
            }
            let state: RideArchiveEvent.State =
                playback.state == .running
                ? .running
                : playback.state == .completed
                    ? .finished : playback.state == .interrupted ? .interrupted : .paused
            if archive.events.last?.state != state || archive.events.last?.intensity != playback.intensity {
                try archive.append(
                    event: RideArchiveEvent(
                        state: state, date: now, activeElapsed: playback.elapsed,
                        intensity: playback.intensity, simulatedDistance: simulation?.metrics.distance))
                stateChanged = true
            }
            if let recordingMetrics { try archive.setRecordingMetrics(recordingMetrics) }
            currentArchive = archive
            let uptime = ProcessInfo.processInfo.systemUptime
            if stateChanged || archiveLastWrite.map({ uptime - $0 >= 5 }) ?? true {
                try archiveStore.save(archive)
                archiveLastWrite = uptime
                archiveError = nil
            }
        } catch {
            currentArchive = archive
            archiveError =
                "Ride checkpoint failed: \(error.localizedDescription). Keep the app open and retry saving before leaving."
            record(archiveError ?? error.localizedDescription)
        }
    }

    func recordWatchMetrics(
        heartRate: Double? = nil, date: Date = Date(), summary: RecordingMetrics? = nil
    ) {
        if let heartRate { receivedHeartRate = (heartRate, date) }
        if let summary { recordingMetrics = summary }
        captureRide()
    }

    func saveArchiveNow() {
        archiveLastWrite = nil
        captureRide()
        if let currentArchive {
            do {
                try archiveStore.save(currentArchive)
                archiveError = nil
            } catch { archiveError = error.localizedDescription }
        }
    }

    func recordHealthReceipt(_ receipt: RideHealthReceipt, rideID: UUID, summary: RecordingMetrics?)
        throws
    {
        if currentArchive?.id == rideID {
            try currentArchive?.setHealthReceipt(receipt)
            if let summary { try currentArchive?.setRecordingMetrics(summary) }
            if let currentArchive { try archiveStore.save(currentArchive) }
        } else {
            try archiveStore.setHealthReceipt(receipt, for: rideID)
            if let summary { try archiveStore.setRecordingMetrics(summary, for: rideID) }
        }
    }

    func reconcileRecoveredDistance(_ distance: Double) {
        guard recoveredWatchRide, playback?.state == .interrupted,
            let configuration = simulation?.configuration, let existing = simulation?.metrics.distance
        else { return }
        do {
            simulation = try RideSimulation(configuration: configuration, recoveredDistance: max(distance, existing))
        } catch {
            simulationRuntimeError = "Recovered Watch distance rejected: \(error.localizedDescription)"
            record(simulationError ?? error.localizedDescription)
        }
    }

    func restoreRide(_ id: UUID) async {
        guard !workoutOwnsTrainer, let archive = archiveStore.ride(id: id), archive.isRecoverable else {
            playbackStatus = "Recovery requires an unfinished local ride and no active ride."
            return
        }
        guard await prepareForRide(), let range = powerRange else { return }
        guard archive.trainer.id == peripheral?.identifier else {
            playbackStatus =
                "Recovery blocked: connect the original trainer \(archive.trainer.name). No target was sent."
            return
        }
        do {
            let elapsed = min(archive.activeDuration, archive.workout.duration.nextDown)
            playback = try WorkoutPlayback(
                recovering: archive.workout, ftp: archive.ftp, range: range,
                elapsed: elapsed, intensity: archive.currentIntensity)
            simulation = try archive.simulation.map {
                try RideSimulation(configuration: $0, recoveredDistance: archive.simulatedDistance ?? 0)
            }
            cadenceEvaluator = try CadenceGuidanceEvaluator(
                configuration: archive.cadenceConfiguration ?? configuration.cadence.snapshot())
            cadenceGuidance = nil
            activeCue = nil
            currentArchive = archive
            playbackID = archive.id
            recoveredWatchRide = archive.recordingMode == .watch
            playbackStatus =
                recoveredWatchRide
                ? "Checkpoint recovered. Reconnect the existing paused recording on Watch, or finish trainer here and end locally on Watch."
                : "Checkpoint recovered. Resume explicitly; no resistance target has been sent."
            captureRide()
            onWorkoutUpdate?()
        } catch {
            playbackStatus =
                "Checkpoint recovery failed: \(error.localizedDescription). No automatic trainer resume."
            record(playbackStatus)
        }
    }

    var canRequestControl: Bool {
        connected && controlSubscribed && powerSupported && powerRange != nil && !pending
            && !stopFlow.isInProgress
            && (!workoutOwnsTrainer || playback?.state == .interrupted || playback?.state == .paused)
    }

    func scan() {
        guard !connected, !isConnecting else { return }
        scanning = true
        scanTimeout?.cancel()
        scanTimeout = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            central?.stopScan()
            scanning = false
            reconnectPreferred = false
            if !connected, !isConnecting {
                status =
                    "Search finished. Select a trainer, or retry with the trainer powered on and Bluetooth enabled."
            }
        }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            devices = []
            central?.scanForPeripherals(withServices: nil)
            status = "Scanning. Select your KICKR; discovery alone does not prove ERG support."
        } else {
            status = "Enable Bluetooth and allow CadenceCore access in Settings."
        }
    }

    func connect(_ device: Device) {
        guard !connected, peripheral == nil else { return }
        central?.stopScan()
        scanning = false
        reconnectPreferred = false
        scanTimeout?.cancel()
        peripheral = device.peripheral
        UserDefaults.standard.set(device.id.uuidString, forKey: "trainerID")
        UserDefaults.standard.set(device.name, forKey: "trainerName")
        device.peripheral.delegate = self
        status = "Connecting to \(device.name)…"
        central?.connect(device.peripheral)
        connectionTimeout?.cancel()
        connectionTimeout = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let peripheral, !connected else { return }
            central?.cancelPeripheralConnection(peripheral)
            preparationError =
                "Connection timed out. Keep the trainer nearby and close other cycling apps before retrying."
            status = preparationError ?? "Connection timed out."
            self.peripheral = nil
        }
    }

    func cancelSearch() {
        preparationCancelled = true
        scanTimeout?.cancel()
        connectionTimeout?.cancel()
        central?.stopScan()
        scanning = false
        reconnectPreferred = false
        if let peripheral, !connected {
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
        }
        preparationError = "Trainer setup cancelled."
    }

    func changeTrainer() {
        guard !workoutOwnsTrainer, !sequenceActive, !trainerRunning, let peripheral else {
            preparationError = "Finish the current ride or reduce load and stop before changing trainers."
            return
        }
        UserDefaults.standard.removeObject(forKey: "trainerID")
        UserDefaults.standard.removeObject(forKey: "trainerName")
        central?.cancelPeripheralConnection(peripheral)
    }

    func requestControl() {
        guard canRequestControl else {
            record("Control request blocked: FTMS capabilities are not ready.")
            return
        }
        send(Data([0x00]))
    }

    func beginSequence() {
        guard !workoutOwnsTrainer, !sequenceActive, hasControl, trainerRunning, !pending,
            !stopFlow.isInProgress,
            let telemetryDate, Date().timeIntervalSince(telemetryDate) <= 3, let range = powerRange,
            range.contains(0),
            (80...120).allSatisfy(range.contains)
        else {
            record(
                "Sequence blocked: fresh telemetry, acknowledged trainer start/control, supported 0 W, and an 80–120 W range in 1 W steps are required."
            )
            return
        }
        sequenceStart = ProcessInfo.processInfo.systemUptime
        activeTestLength = testLength
        sequenceTarget = nil
        lastSequenceSampleTime = nil
        sequenceActive = true
        record(
            "\(activeTestLength.rawValue)-minute diagnostic sequence armed. Targets: 80 W / 100 W / 100–120 W ramp / 80 W, \(Int(activeTestLength.stageDuration)) seconds each."
        )
        serviceSequence()
    }

    private func serviceSequence() {
        guard let start = sequenceStart, hasControl, !pending else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if lastSequenceSampleTime.map({ elapsed - $0 >= 15 }) ?? true {
            lastSequenceSampleTime = elapsed
            record(
                "Telemetry elapsed \(String(format: "%.3f", elapsed)) s, measured power \(power.map { "\($0) W" } ?? "unavailable"), cadence \(cadence.map { String(format: "%.1f rpm", $0) } ?? "unavailable")."
            )
        }
        guard let target = DiagnosticSchedule.target(at: elapsed, length: activeTestLength) else {
            sequenceStart = nil
            sequenceActive = false
            record(
                "Diagnostic timeline complete after \(elapsed) seconds; requesting acknowledged 0 W before stop."
            )
            stopTrainer()
            return
        }
        guard target != sequenceTarget else { return }
        sequenceTarget = target
        record("Timeline elapsed \(elapsed) seconds, scheduled target \(target) W.")
        setTarget(target)
    }

    func setTarget(_ watts: Int) {
        guard !workoutOwnsTrainer, !stopFlow.isInProgress, hasControl, let range = powerRange,
            range.contains(watts),
            let signed = Int16(exactly: watts)
        else {
            record("Target rejected: acquire control and use a supported power increment/range.")
            return
        }
        if stopFlow.state == .completed || stopFlow.state == .failed {
            stopFlow = ReducedLoadStop()
            stopStatus = "Target changed; reduced-load stop has not been requested."
        }
        send(FTMS.targetPower(signed))
    }

    func startTrainer() {
        guard !workoutOwnsTrainer, hasControl, !stopFlow.isInProgress, !sequenceActive else {
            record(
                "Start rejected: acquire control and wait for the active diagnostic or stop flow to finish."
            )
            return
        }
        send(Data([0x07]))
    }

    func stopTrainer() {
        defer { onWorkoutUpdate?() }
        simulation?.suspend()
        if workoutOwnsTrainer, let state = playback?.state,
            ![.pausing, .finishing, .interrupted].contains(state)
        {
            _ = playback?.finish(now: ProcessInfo.processInfo.systemUptime)
        }
        sequenceStart = nil
        sequenceActive = false
        guard !stopFlow.isInProgress else { return }
        guard hasControl, connected, controlSubscribed, powerRange?.contains(0) == true else {
            failStop(
                "Cannot request reduced load: control/connection or supported 0 W target unavailable.")
            return
        }
        stopStatus =
            pending ? "Waiting for the pending command, then requesting 0 W…" : "Requesting 0 W…"
        record("Reduced-load stop requested. 0 W acknowledgment is required before sending FTMS stop.")
        if let command = stopFlow.begin(commandPending: pending) {
            sendStopCommand(command)
        }
    }

    private func sendStopCommand(_ command: ReducedLoadStop.Command) {
        switch command {
        case .zeroWatts:
            stopStatus = "Requesting 0 W…"
            send(FTMS.targetPower(0))
        case .stop:
            stopStatus = "0 W acknowledged; sending FTMS stop…"
            record("Reduced-load target 0 W acknowledged. This does not guarantee zero resistance.")
            send(Data([0x08, 0x01]))
        }
    }

    private func failStop(_ reason: String) {
        interruptWorkout("Reduced-load stop failed. \(reason)")
        stopFlow.fail()
        stopStatus = "Trainer state unconfirmed. \(reason)"
        record(stopStatus)
    }

    func disconnect() {
        guard let peripheral else { return }
        interruptWorkout(
            "Disconnect requested; workout frozen. The trainer may retain its last target.")
        record(
            "Disconnect requested. The trainer may retain its last target; this is NOT a load release.")
        central?.cancelPeripheralConnection(peripheral)
    }

    private func send(_ data: Data) {
        guard !pending, connected, controlSubscribed, let peripheral, let controlPoint,
            let opcode = data.first
        else {
            record("Command not sent: control point unavailable or another command is pending.")
            interruptWorkout("Trainer command could not be sent; state unconfirmed.")
            if stopFlow.isInProgress { failStop("Reduced-load stop command could not be sent.") }
            return
        }
        pending = true
        pendingOpcode = opcode
        record(
            "Issued FTMS opcode \(opcode), payload \(data.map { String(format: "%02X", $0) }.joined(separator: " "))."
        )
        peripheral.writeValue(data, for: controlPoint, type: .withResponse)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.pendingOpcode == opcode else { return }
            self.clearPending()
            self.interruptWorkout("Trainer command timed out; reacquire control before resuming.")
            self.hasControl = false
            self.trainerRunning = false
            self.sequenceStart = nil
            self.sequenceActive = false
            if self.stopFlow.isInProgress {
                self.failStop("Command \(opcode) timed out; reacquire control before retrying.")
            }
            self.record("Command \(opcode) timed out. Trainer state unconfirmed; reacquire control.")
        }
    }

    private func clearPending() {
        timeout?.cancel()
        timeout = nil
        pending = false
        pendingOpcode = nil
    }

    private func record(_ message: String) {
        events.append("\(formatter.string(from: Date())) \(message)")
        if events.count > 500 { events.removeFirst(events.count - 500) }
        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let url = directory.appendingPathComponent("trainer-diagnostic.txt")
            try Data(events.joined(separator: "\n").utf8).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            diagnosticFile = url
            persistenceError = nil
        } catch {
            persistenceError = "Cannot save diagnostic log: \(error.localizedDescription)"
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanning { scan() }
        case .poweredOff:
            status = "Bluetooth is off. Trainer state unconfirmed."
        case .unauthorized:
            status = "Bluetooth access denied. Enable it in Settings."
        case .unsupported:
            status = "Bluetooth Low Energy is unavailable on this device."
        case .resetting:
            status = "Bluetooth is resetting. Trainer state unconfirmed."
        case .unknown:
            status = "Waiting for Bluetooth."
        @unknown default:
            status = "Unknown Bluetooth state."
        }
        if central.state != .poweredOn {
            interruptWorkout("Bluetooth unavailable; workout frozen and trainer state unconfirmed.")
            if stopFlow.state != .idle {
                failStop("Bluetooth is unavailable; load reduction cannot be confirmed.")
            }
            hasControl = false
            trainerRunning = false
            sequenceStart = nil
            sequenceActive = false
            clearPending()
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name else { return }
        if !devices.contains(where: { $0.id == peripheral.identifier }) {
            devices.append(Device(id: peripheral.identifier, name: name, peripheral: peripheral))
        }
        let resumable = playback.map { [.paused, .interrupted].contains($0.state) } ?? false
        if reconnectPreferred, !workoutOwnsTrainer || resumable, !sequenceActive,
            peripheral.identifier.uuidString == UserDefaults.standard.string(forKey: "trainerID")
        {
            reconnectPreferred = false
            connect(Device(id: peripheral.identifier, name: name, peripheral: peripheral))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectionTimeout?.cancel()
        connected = true
        services = []
        status = "Inspecting all advertised GATT services."
        record("Connected. Discovering GATT services; no trainer commands sent.")
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        connectionTimeout?.cancel()
        self.peripheral = nil
        status = "Connection failed: \(error?.localizedDescription ?? "Bluetooth supplied no reason")."
        record(status)
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        interruptWorkout("Trainer disconnected; workout frozen. Reconnect and resume explicitly.")
        if stopFlow.state != .idle {
            failStop("Connection ended; current trainer load cannot be confirmed.")
        }
        connected = false
        sequenceStart = nil
        sequenceActive = false
        hasControl = false
        trainerRunning = false
        powerSupported = false
        powerRange = nil
        controlPoint = nil
        controlSubscribed = false
        self.peripheral = nil
        clearPending()
        power = nil
        cadence = nil
        telemetryDate = nil
        status = "Disconnected. Trainer state unconfirmed."
        record("\(status) \(error?.localizedDescription ?? "Connection ended").")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = error.localizedDescription
            record("Service discovery failed: \(status)")
            return
        }
        for service in peripheral.services ?? [] {
            services.append(service.uuid.uuidString)
            record("Service \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if !(peripheral.services ?? []).contains(where: { $0.uuid == CBUUID(string: "1826") }) {
            status = "No FTMS service found. ERG control is blocked pending a verified Wahoo protocol."
            record(status)
        } else {
            status = "FTMS found. Checking power capabilities and control indications."
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        if let error {
            record("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            record(
                "Characteristic \(service.uuid.uuidString)/\(characteristic.uuid.uuidString), properties \(characteristic.properties.rawValue)"
            )
            if service.uuid == CBUUID(string: "180A"),
                ["2A26", "2A24", "2A29"].contains(characteristic.uuid.uuidString),
                characteristic.properties.contains(.read)
            {
                peripheral.readValue(for: characteristic)
            }
            guard service.uuid == CBUUID(string: "1826") else { continue }
            switch characteristic.uuid.uuidString {
            case "2ACC", "2AD8":
                if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
            case "2AD2":
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            case "2AD9":
                if characteristic.properties.contains(.write)
                    && characteristic.properties.contains(.indicate)
                {
                    controlPoint = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else {
                    record("FTMS control point lacks required write/indicate properties. Control blocked.")
                }
            default: break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            if characteristic.uuid == CBUUID(string: "2AD9") {
                interruptWorkout("Trainer control subscription failed: \(error.localizedDescription)")
                hasControl = false
            }
            record("Subscription failed: \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == CBUUID(string: "2AD9") {
            controlSubscribed = characteristic.isNotifying
            if !controlSubscribed {
                interruptWorkout("Trainer control indications were disabled; workout frozen.")
                hasControl = false
                if stopFlow.isInProgress {
                    failStop("Control indications unavailable; reduced load is unconfirmed.")
                }
                clearPending()
            }
            record("FTMS control indications \(controlSubscribed ? "enabled" : "disabled").")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            interruptWorkout("Trainer write failed: \(error.localizedDescription)")
            if stopFlow.isInProgress { failStop("Bluetooth write failed: \(error.localizedDescription)") }
            clearPending()
            hasControl = false
            trainerRunning = false
            sequenceStart = nil
            sequenceActive = false
            record("Write failed; trainer state unconfirmed: \(error.localizedDescription)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        defer { if characteristic.uuid == CBUUID(string: "2AD9") { onWorkoutUpdate?() } }
        if let error {
            if characteristic.uuid == CBUUID(string: "2AD2") { simulation?.suspend() }
            record("Read/notification failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else {
            if characteristic.uuid == CBUUID(string: "2AD2") { simulation?.suspend() }
            record("Empty characteristic value.")
            return
        }
        do {
            switch characteristic.uuid.uuidString {
            case "2A26", "2A24", "2A29":
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ProtocolError.invalidResponse
                }
                record("Device information \(characteristic.uuid.uuidString): \(text)")
            case "2ACC":
                powerSupported = try FTMS.supportsTargetPower(data)
                record("Target power feature \(powerSupported ? "supported" : "not supported").")
            case "2AD8":
                powerRange = try PowerRange.decode(data)
                if let range = powerRange {
                    record("Power range \(range.minimum)…\(range.maximum) W, increment \(range.increment) W.")
                }
            case "2AD2":
                let sample = try IndoorBikeData.decode(data)
                power = sample.power
                cadence = sample.cadence
                telemetryDate = Date()
                serviceSequence()
                serviceWorkout(telemetrySample: true)
            case "2AD9":
                let response = try FTMS.response(data)
                guard response.opcode == pendingOpcode else {
                    record(
                        "Unexpected control response for opcode \(response.opcode); not counted as success.")
                    return
                }
                clearPending()
                if response.result == 1 {
                    if response.opcode == 0 { hasControl = true }
                    if response.opcode == 7 { trainerRunning = true }
                    if response.opcode == 8 { trainerRunning = false }
                    record("Acknowledged FTMS opcode \(response.opcode).")
                    if stopFlow.isInProgress {
                        if let next = stopFlow.commandAcknowledged() {
                            sendStopCommand(next)
                        } else if stopFlow.state == .completed {
                            stopStatus = "0 W and stop acknowledged. Reduced load requested—not zero resistance."
                            record(stopStatus)
                            playback?.stopped()
                            if let playback {
                                playbackStatus = playback.error ?? "Workout \(playback.state.rawValue)."
                            }
                        }
                    } else if let command = playback?.acknowledged(
                        opcode: response.opcode, now: ProcessInfo.processInfo.systemUptime
                    ) {
                        perform(command)
                    } else if playback?.state == .running {
                        playbackStatus = "Workout running."
                        if response.opcode == 7 { monitorWorkoutTelemetry() }
                    }
                } else {
                    interruptWorkout(
                        "Trainer rejected command \(response.opcode), result \(response.result).")
                    if stopFlow.isInProgress {
                        failStop("Trainer rejected opcode \(response.opcode), result \(response.result).")
                    }
                    hasControl = false
                    trainerRunning = false
                    sequenceStart = nil
                    sequenceActive = false
                    record(
                        "Trainer rejected opcode \(response.opcode), result \(response.result). State unconfirmed."
                    )
                }
            default: break
            }
        } catch {
            if characteristic.uuid == CBUUID(string: "2AD2") { simulation?.suspend() }
            if characteristic.uuid == CBUUID(string: "2AD9") {
                interruptWorkout("Malformed trainer response; state unconfirmed.")
                clearPending()
                hasControl = false
                trainerRunning = false
            }
            if characteristic.uuid == CBUUID(string: "2AD9"), stopFlow.isInProgress {
                failStop("Malformed control response: \(error.localizedDescription)")
                clearPending()
                hasControl = false
                trainerRunning = false
            }
            record("Malformed \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        }
    }
}
