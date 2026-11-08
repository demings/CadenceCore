import CoreBluetooth
import Foundation
import Observation

@MainActor @Observable
// Both central and peripheral delegates are delivered on the explicitly selected main queue.
final class TrainerDiagnostic: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
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

    override init() {
        super.init()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let url = directory.appendingPathComponent("trainer-diagnostic.txt")
            if FileManager.default.fileExists(atPath: url.path) {
                events = Array(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init).suffix(500))
                diagnosticFile = url
            }
        } catch {
            persistenceError = "Cannot restore diagnostic log: \(error.localizedDescription)"
        }
    }

    var canRequestControl: Bool {
        connected && controlSubscribed && powerSupported && powerRange != nil && !pending && !stopFlow.isInProgress
    }

    func scan() {
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
        peripheral = device.peripheral
        device.peripheral.delegate = self
        status = "Connecting to \(device.name)…"
        central?.connect(device.peripheral)
    }

    func requestControl() {
        guard canRequestControl else { record("Control request blocked: FTMS capabilities are not ready."); return }
        send(Data([0x00]))
    }

    func beginSequence() {
        guard !sequenceActive, hasControl, trainerRunning, !pending, !stopFlow.isInProgress,
              let telemetryDate, Date().timeIntervalSince(telemetryDate) <= 3, let range = powerRange,
              range.contains(0),
              (80...120).allSatisfy(range.contains) else {
            record("Sequence blocked: fresh telemetry, acknowledged trainer start/control, supported 0 W, and an 80–120 W range in 1 W steps are required.")
            return
        }
        sequenceStart = ProcessInfo.processInfo.systemUptime
        activeTestLength = testLength
        sequenceTarget = nil
        lastSequenceSampleTime = nil
        sequenceActive = true
        record("\(activeTestLength.rawValue)-minute diagnostic sequence armed. Targets: 80 W / 100 W / 100–120 W ramp / 80 W, \(Int(activeTestLength.stageDuration)) seconds each.")
        serviceSequence()
    }

    private func serviceSequence() {
        guard let start = sequenceStart, hasControl, !pending else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if lastSequenceSampleTime.map({ elapsed - $0 >= 15 }) ?? true {
            lastSequenceSampleTime = elapsed
            record("Telemetry elapsed \(String(format: "%.3f", elapsed)) s, measured power \(power.map { "\($0) W" } ?? "unavailable"), cadence \(cadence.map { String(format: "%.1f rpm", $0) } ?? "unavailable").")
        }
        guard let target = DiagnosticSchedule.target(at: elapsed, length: activeTestLength) else {
            sequenceStart = nil
            sequenceActive = false
            record("Diagnostic timeline complete after \(elapsed) seconds; requesting acknowledged 0 W before stop.")
            stopTrainer()
            return
        }
        guard target != sequenceTarget else { return }
        sequenceTarget = target
        record("Timeline elapsed \(elapsed) seconds, scheduled target \(target) W.")
        setTarget(target)
    }

    func setTarget(_ watts: Int) {
        guard !stopFlow.isInProgress, hasControl, let range = powerRange, range.contains(watts),
              let signed = Int16(exactly: watts) else {
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
        guard hasControl, !stopFlow.isInProgress, !sequenceActive else {
            record("Start rejected: acquire control and wait for the active diagnostic or stop flow to finish.")
            return
        }
        send(Data([0x07]))
    }

    func stopTrainer() {
        sequenceStart = nil
        sequenceActive = false
        guard !stopFlow.isInProgress else { return }
        guard hasControl, connected, controlSubscribed, powerRange?.contains(0) == true else {
            failStop("Cannot request reduced load: control/connection or supported 0 W target unavailable.")
            return
        }
        stopStatus = pending ? "Waiting for the pending command, then requesting 0 W…" : "Requesting 0 W…"
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
        stopFlow.fail()
        stopStatus = "Trainer state unconfirmed. \(reason)"
        record(stopStatus)
    }

    func disconnect() {
        guard let peripheral else { return }
        record("Disconnect requested. The trainer may retain its last target; this is NOT a load release.")
        central?.cancelPeripheralConnection(peripheral)
    }

    private func send(_ data: Data) {
        guard !pending, connected, controlSubscribed, let peripheral, let controlPoint,
              let opcode = data.first else {
            record("Command not sent: control point unavailable or another command is pending.")
            if stopFlow.isInProgress { failStop("Reduced-load stop command could not be sent.") }
            return
        }
        pending = true
        pendingOpcode = opcode
        record("Issued FTMS opcode \(opcode), payload \(data.map { String(format: "%02X", $0) }.joined(separator: " ")).")
        peripheral.writeValue(data, for: controlPoint, type: .withResponse)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self, self.pendingOpcode == opcode else { return }
            self.clearPending()
            self.hasControl = false
            self.trainerRunning = false
            self.sequenceStart = nil
            self.sequenceActive = false
            if self.stopFlow.isInProgress { self.failStop("Command \(opcode) timed out; reacquire control before retrying.") }
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
            scan()
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
            if stopFlow.state != .idle { failStop("Bluetooth is unavailable; load reduction cannot be confirmed.") }
            hasControl = false
            trainerRunning = false
            sequenceStart = nil
            sequenceActive = false
            clearPending()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name else { return }
        devices.append(Device(id: peripheral.identifier, name: name, peripheral: peripheral))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        services = []
        status = "Inspecting all advertised GATT services."
        record("Connected. Discovering GATT services; no trainer commands sent.")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        status = "Connection failed: \(error?.localizedDescription ?? "Bluetooth supplied no reason")."
        record(status)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if stopFlow.state != .idle { failStop("Connection ended; current trainer load cannot be confirmed.") }
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
        if let error { status = error.localizedDescription; record("Service discovery failed: \(status)"); return }
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

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { record("Characteristic discovery failed: \(error.localizedDescription)"); return }
        for characteristic in service.characteristics ?? [] {
            record("Characteristic \(service.uuid.uuidString)/\(characteristic.uuid.uuidString), properties \(characteristic.properties.rawValue)")
            if service.uuid == CBUUID(string: "180A"),
               ["2A26", "2A24", "2A29"].contains(characteristic.uuid.uuidString),
               characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            guard service.uuid == CBUUID(string: "1826") else { continue }
            switch characteristic.uuid.uuidString {
            case "2ACC", "2AD8":
                if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
            case "2AD2":
                if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
            case "2AD9":
                if characteristic.properties.contains(.write) && characteristic.properties.contains(.indicate) {
                    controlPoint = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else {
                    record("FTMS control point lacks required write/indicate properties. Control blocked.")
                }
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { record("Subscription failed: \(error.localizedDescription)"); return }
        if characteristic.uuid == CBUUID(string: "2AD9") {
            controlSubscribed = characteristic.isNotifying
            record("FTMS control indications \(controlSubscribed ? "enabled" : "disabled").")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if stopFlow.isInProgress { failStop("Bluetooth write failed: \(error.localizedDescription)") }
            clearPending()
            hasControl = false
            trainerRunning = false
            sequenceStart = nil
            sequenceActive = false
            record("Write failed; trainer state unconfirmed: \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { record("Read/notification failed: \(error.localizedDescription)"); return }
        guard let data = characteristic.value else { record("Empty characteristic value."); return }
        do {
            switch characteristic.uuid.uuidString {
            case "2A26", "2A24", "2A29":
                guard let text = String(data: data, encoding: .utf8) else { throw ProtocolError.invalidResponse }
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
            case "2AD9":
                let response = try FTMS.response(data)
                guard response.opcode == pendingOpcode else {
                    record("Unexpected control response for opcode \(response.opcode); not counted as success.")
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
                        }
                    }
                } else {
                    if stopFlow.isInProgress { failStop("Trainer rejected opcode \(response.opcode), result \(response.result).") }
                    hasControl = false
                    trainerRunning = false
                    sequenceStart = nil
                    sequenceActive = false
                    record("Trainer rejected opcode \(response.opcode), result \(response.result). State unconfirmed.")
                }
            default: break
            }
        } catch {
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
