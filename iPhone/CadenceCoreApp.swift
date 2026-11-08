import SwiftUI

@main
struct CadenceCoreApp: App {
    @State private var trainer = TrainerDiagnostic()
    @State private var watch = WatchMirror()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                DiagnosticView(trainer: trainer, watch: watch)
            }
            .tint(.teal)
        }
    }
}

struct DiagnosticView: View {
    @Bindable var trainer: TrainerDiagnostic
    @Bindable var watch: WatchMirror
    @State private var watts = 100
    @State private var confirmTarget = false
    @State private var confirmSequence = false

    var body: some View {
        List {
            Section {
                Label("Hardware feasibility • Diagnostic build", systemImage: "wrench.and.screwdriver")
                Text("This is not yet a workout player. Reduced-load stop requests 0 W before FTMS stop. Neither acknowledgment nor disconnect guarantees zero resistance.")
                    .font(.footnote)
            }
            Section("Trainer") {
                Text(trainer.status)
                if !trainer.connected {
                    Button("Scan for trainer", systemImage: "antenna.radiowaves.left.and.right") { trainer.scan() }
                    ForEach(trainer.devices) { device in
                        Button(device.name) { trainer.connect(device) }
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let fresh = trainer.telemetryDate.map { context.date.timeIntervalSince($0) <= 3 } ?? false
                        LabeledContent("Measured power", value: fresh ? trainer.power.map { "\($0) W" } ?? "Unavailable" : "Unavailable / stale")
                        LabeledContent("Cadence", value: fresh ? trainer.cadence.map { "\(Int($0.rounded())) rpm" } ?? "Unavailable" : "Unavailable / stale")
                    }
                    Button("Request FTMS control") { trainer.requestControl() }
                        .disabled(!trainer.canRequestControl)
                    if let range = trainer.powerRange {
                        Text("Supported: \(range.minimum)–\(range.maximum) W in \(range.increment) W steps")
                            .font(.caption)
                    }
                    Stepper("Diagnostic target: \(watts) W", value: $watts, in: 0...400, step: 5)
                    Button("Send target power") { confirmTarget = true }
                        .disabled(trainer.sequenceActive || trainer.stopFlow.isInProgress || !trainer.hasControl || trainer.pending || !(trainer.powerRange?.contains(watts) ?? false))
                    Button("Send start / resume") { trainer.startTrainer() }
                        .disabled(trainer.sequenceActive || trainer.stopFlow.isInProgress || !trainer.hasControl || trainer.pending)
                    Button("Reduce load to 0 W and stop", role: .destructive) { trainer.stopTrainer() }
                        .disabled(trainer.stopFlow.isInProgress || !trainer.hasControl)
                    Text(trainer.stopStatus)
                        .font(.footnote)
                        .foregroundStyle(trainer.stopFlow.state == .failed ? Color.red : Color.secondary)
                    Picker("Test duration", selection: $trainer.testLength) {
                        ForEach(DiagnosticSchedule.Length.allCases, id: \.self) { length in
                            Text("\(length.rawValue) minutes").tag(length)
                        }
                    }
                    .disabled(trainer.sequenceActive || trainer.stopFlow.isInProgress)
                    Button(trainer.sequenceActive ? "Diagnostic running" : "Arm \(trainer.testLength.rawValue)-minute background test") {
                        confirmSequence = true
                    }
                    .disabled(trainer.sequenceActive || trainer.stopFlow.isInProgress || !trainer.hasControl || !trainer.trainerRunning || trainer.pending)
                    Button("Disconnect (does not release load)", role: .destructive) { trainer.disconnect() }
                }
            }
            Section("Apple Watch heart rate") {
                Text(watch.status)
                Button("Enable Watch diagnostic mirroring") { Task { await watch.prepare() } }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = watch.receivedAt.map { context.date.timeIntervalSince($0) <= 10 } ?? false
                    LabeledContent("Heart rate", value: fresh ? watch.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "Unavailable" : "Unavailable / stale")
                }
                Text("Diagnostic Watch sessions are discarded, not saved to Fitness.")
                    .font(.footnote)
            }
            Section("Discovered services") {
                ForEach(trainer.services, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
            Section("Timestamped diagnostic log") {
                if let error = trainer.persistenceError { Text(error).foregroundStyle(.red) }
                if let url = trainer.diagnosticFile {
                    ShareLink("Export diagnostic log", item: url)
                }
                ForEach(Array(trainer.events.suffix(30).enumerated()), id: \.offset) { _, event in
                    Text(event).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("CadenceCore")
        .confirmationDialog("Send \(watts) W to the trainer?", isPresented: $confirmTarget, titleVisibility: .visible) {
            Button("Send \(watts) W") { trainer.setTarget(watts) }
        } message: {
            Text("ERG resistance may increase as cadence falls. The reduced-load stop requests 0 W but cannot guarantee zero resistance.")
        }
        .confirmationDialog("Arm the diagnostic sequence?", isPresented: $confirmSequence, titleVisibility: .visible) {
            Button("Arm \(trainer.testLength.rawValue)-minute sequence") { trainer.beginSequence() }
        } message: {
            Text("First send a target and start the trainer manually. Each stage lasts \(Int(trainer.testLength.stageDuration)) seconds: 80 W, 100 W, a 100–120 W ramp, then 80 W. With ongoing telemetry, completion requests 0 W, waits for acknowledgment, then sends stop. If telemetry or the app stops, the last target may remain active. Logs include measured power/cadence every 15 seconds.")
        }
    }
}
