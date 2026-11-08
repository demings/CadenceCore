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
                Text("This is not yet a workout player. Commands can change resistance. Stop/disconnect behavior must be verified on your trainer.")
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
                        .disabled(trainer.sequenceActive || !trainer.hasControl || trainer.pending || !(trainer.powerRange?.contains(watts) ?? false))
                    Button("Send start / resume") { trainer.startTrainer() }
                        .disabled(!trainer.hasControl || trainer.pending)
                    Button("Send stop", role: .destructive) { trainer.stopTrainer() }
                        .disabled(!trainer.hasControl || trainer.pending)
                    Button(trainer.sequenceActive ? "20-minute diagnostic running" : "Arm 20-minute background test") {
                        confirmSequence = true
                    }
                    .disabled(trainer.sequenceActive || !trainer.hasControl || !trainer.trainerRunning || trainer.pending)
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
            Text("ERG resistance may increase as cadence falls. This diagnostic does not implement workout progression or automatic load release.")
        }
        .confirmationDialog("Arm the diagnostic sequence?", isPresented: $confirmSequence, titleVisibility: .visible) {
            Button("Arm 80–120 W sequence") { trainer.beginSequence() }
        } message: {
            Text("First send a target and start the trainer manually. The test changes target every five minutes, including a ramp. It uses telemetry callbacks while locked and sends stop at completion if telemetry continues. If telemetry or the app stops, the last target may remain active.")
        }
    }
}
