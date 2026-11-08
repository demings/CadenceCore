import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts

@main
struct CadenceCoreApp: App {
    @State private var trainer = TrainerDiagnostic()
    @State private var watch = WatchMirror()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { WorkoutLibraryView() }
                    .tabItem { Label("Workouts", systemImage: "list.bullet.rectangle") }
                NavigationStack { DiagnosticView(trainer: trainer, watch: watch) }
                    .tabItem { Label("Diagnostics", systemImage: "wrench.and.screwdriver") }
            }
            .tint(.teal)
        }
        .modelContainer(for: SavedWorkout.self)
    }

    struct WorkoutLibraryView: View {
        @Environment(\.modelContext) private var context
        @Query(sort: \SavedWorkout.createdAt, order: .reverse) private var workouts: [SavedWorkout]
        @AppStorage("ftpWatts") private var ftp = ""
        @State private var importing = false
        @State private var errorMessage: String?

        var body: some View {
            List {
                Section("Your FTP") {
                    TextField("FTP in watts", text: $ftp).keyboardType(.numberPad)
                    if let value = Double(ftp), value.isFinite, (1...2000).contains(value) {
                        Text("Preview targets use \(Int(value)) W FTP.").font(.caption)
                    } else {
                        Text("Enter FTP from 1–2000 W to preview watt targets. No default is assumed.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section {
                    Text("Import and preview workouts. Full ERG playback is not available yet; use Diagnostics for the hardware test.")
                        .font(.footnote)
                    Button("Import ZWO", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Add original example", systemImage: "plus") { save(.sample, source: nil) }
                }
                Section("Library") {
                    if workouts.isEmpty {
                        ContentUnavailableView("No workouts yet", systemImage: "bicycle",
                                               description: Text("Import a cycling ZWO file or add the original example."))
                    }
                    ForEach(workouts) { saved in
                        NavigationLink {
                            WorkoutPreviewView(saved: saved, ftpText: ftp)
                        } label: {
                            HStack {
                                if saved.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                Text(saved.name)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button(saved.favorite ? "Unfavorite" : "Favorite") {
                                saved.favorite.toggle()
                                persist()
                            }.tint(.orange)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                context.delete(saved)
                                persist()
                            }
                            Button("Duplicate") {
                                do {
                                    var workout = try JSONDecoder().decode(Workout.self, from: saved.encodedWorkout)
                                    workout.name = saved.name + " copy"
                                    save(workout, source: saved.source)
                                } catch { errorMessage = error.localizedDescription }
                            }.tint(.teal)
                        }
                    }
                }
            }
            .navigationTitle("Workouts")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    guard url.pathExtension.lowercased() == "zwo" else {
                        throw WorkoutImportError.invalid("choose a .zwo file.")
                    }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    let data: Data
                    do {
                        data = try handle.read(upToCount: ZWOImporter.maximumFileBytes + 1) ?? Data()
                    } catch {
                        try handle.close()
                        throw error
                    }
                    try handle.close()
                    save(try ZWOImporter.parse(data), source: data)
                } catch { errorMessage = error.localizedDescription }
            }
            .alert("Workout library error", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }

        private func save(_ workout: Workout, source: Data?) {
            do {
                context.insert(try SavedWorkout(workout: workout, source: source))
                try context.save()
            } catch {
                context.rollback()
                errorMessage = "Workout was not saved: \(error.localizedDescription)"
            }
        }

        private func persist() {
            do { try context.save() }
            catch {
                context.rollback()
                errorMessage = "Library change was not saved: \(error.localizedDescription)"
            }
        }
    }

    struct WorkoutPreviewView: View {
        @Bindable var saved: SavedWorkout
        let ftpText: String
        @Environment(\.modelContext) private var context
        @State private var workout: Workout?
        @State private var errorMessage: String?
        @State private var editingName = ""
        @State private var renaming = false

        private var ftp: Double? {
            guard let value = Double(ftpText), value.isFinite, (1...2000).contains(value) else { return nil }
            return value
        }

        private struct ProfilePoint: Identifiable {
            let id: Int
            let minutes: Double
            let percent: Double
        }

        private func profile(_ workout: Workout) -> [ProfilePoint] {
            var elapsed: Double = 0
            return workout.intervals.enumerated().flatMap { index, interval in
                let start = elapsed
                elapsed += interval.duration
                return [
                    ProfilePoint(id: index * 2, minutes: start / 60, percent: interval.startPower * 100),
                    ProfilePoint(id: index * 2 + 1, minutes: elapsed / 60, percent: interval.endPower * 100)
                ]
            }
        }

        var body: some View {
            List {
                if let workout {
                    Section {
                        Text(workout.description)
                        LabeledContent("Duration", value: "\(Int(workout.duration / 60)) min \(Int(workout.duration) % 60) sec")
                        Text("Preview only—Start workout will be added after the workout engine is implemented.")
                            .font(.footnote)
                    }
                    Section("Workout profile (% FTP)") {
                        Chart(profile(workout)) { point in
                            AreaMark(x: .value("Minutes", point.minutes), y: .value("% FTP", point.percent))
                                .foregroundStyle(.teal.opacity(0.25))
                            LineMark(x: .value("Minutes", point.minutes), y: .value("% FTP", point.percent))
                                .foregroundStyle(.teal)
                        }
                        .frame(height: 160)
                        .accessibilityLabel("Workout power profile. Full interval values are listed below.")
                    }
                    if !workout.warnings.isEmpty {
                        Section("Import warnings") {
                            ForEach(workout.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                        }
                    }
                    Section("Intervals") {
                        ForEach(Array(workout.intervals.enumerated()), id: \.offset) { index, interval in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(interval.duration.formatted(.number.precision(.fractionLength(0...1)))) seconds").font(.headline)
                                Text("\(Int((interval.startPower * 100).rounded()))–\(Int((interval.endPower * 100).rounded()))% FTP")
                                if let ftp {
                                    Text("\(Int((interval.startPower * ftp).rounded()))–\(Int((interval.endPower * ftp).rounded())) W")
                                }
                                if let cadence = interval.cadence { Text("Workout cadence: \(Int(cadence)) rpm") }
                            }.monospacedDigit()
                        }
                    }
                } else if let errorMessage {
                    ContentUnavailableView("Cannot read workout", systemImage: "exclamationmark.triangle",
                                           description: Text(errorMessage))
                }
            }
            .navigationTitle(saved.name)
            .toolbar {
                Button("Rename") { editingName = saved.name; renaming = true }
            }
            .task {
                do { workout = try JSONDecoder().decode(Workout.self, from: saved.encodedWorkout) }
                catch { errorMessage = error.localizedDescription }
            }
            .alert("Rename workout", isPresented: $renaming) {
                TextField("Name", text: $editingName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { errorMessage = "Workout name cannot be empty."; return }
                    saved.name = name
                    do { try context.save() }
                    catch { context.rollback(); errorMessage = error.localizedDescription }
                }
            }
            .alert("Workout error", isPresented: Binding(
                get: { workout != nil && errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
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
