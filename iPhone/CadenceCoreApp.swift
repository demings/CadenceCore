import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts

@main
struct CadenceCoreApp: App {
    @State private var trainer: TrainerDiagnostic
    @State private var watch: WatchMirror

    init() {
        let trainer = TrainerDiagnostic(configuration: RideConfiguration())
        _trainer = State(initialValue: trainer)
        _watch = State(initialValue: WatchMirror(trainer: trainer))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { WorkoutLibraryView(trainer: trainer, watch: watch) }
                    .tabItem { Label("Workouts", systemImage: "list.bullet.rectangle") }
                NavigationStack { RideHomeView(trainer: trainer, watch: watch) }
                    .tabItem { Label("Ride", systemImage: "bicycle") }
                NavigationStack { AppSettingsView(trainer: trainer, watch: watch) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(.teal)
        }
        .modelContainer(for: SavedWorkout.self)
    }
}

struct WorkoutLibraryView: View {
        @Bindable var trainer: TrainerDiagnostic
        @Bindable var watch: WatchMirror
        @Environment(\.modelContext) private var context
        @Query(sort: \SavedWorkout.createdAt, order: .reverse) private var workouts: [SavedWorkout]
        @State private var importing = false
        @State private var errorMessage: String?
        @State private var deleting: SavedWorkout?

        var body: some View {
            List {
                Section {
                    Text("Choose a workout, prepare its devices, then start on Watch. Setup and readiness are all on the workout screen.")
                        .font(.footnote)
                    Button("Import ZWO", systemImage: "square.and.arrow.down") {
                        importing = true
                    }
                    Button("Add original example", systemImage: "plus") {
                        save(.sample, source: nil)
                    }
                }
                if trainer.playback != nil {
                    Section("Current ride") {
                        NavigationLink("Open ride controls") { RideView(trainer: trainer, watch: watch) }
                    }
                }
                Section("Library") {
                    if workouts.isEmpty {
                        ContentUnavailableView("No workouts yet", systemImage: "bicycle",
                                               description: Text("Import a cycling ZWO file or add the original example."))
                    }
                    ForEach(workouts) { saved in
                        NavigationLink {
                            WorkoutPreviewView(saved: saved, trainer: trainer, watch: watch)
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
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                deleting = saved
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Workouts")
            .alert("Delete this workout?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            )) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete workout", role: .destructive) {
                    guard let deleting else { return }
                    context.delete(deleting)
                    persist()
                    self.deleting = nil
                }
            } message: {
                Text("This removes the library copy. It does not remove an original ZWO file or a workout saved to Health.")
            }
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
        @Bindable var trainer: TrainerDiagnostic
        @Bindable var watch: WatchMirror
        @Environment(\.modelContext) private var context
        @State private var workout: Workout?
        @State private var errorMessage: String?
        @State private var editingName = ""
        @State private var renaming = false
        @State private var confirmStart = false
        @State private var confirmWatch = false
        @State private var showingRide = false
        @State private var localStarting = false

        private var ftp: Double? {
            trainer.configuration.ftp
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
                        Text("Send to Watch for controls and Health recording. iPhone-only playback does not save a ride.")
                            .font(.footnote)
                    }
                    Section("1 · Training targets") { FTPSettingView(configuration: trainer.configuration) }
                    Section("2 · Trainer") { TrainerSetupView(trainer: trainer) }
                    Section("3 · Start your ride") {
                        Label(watch.watchReachable ? "Watch app reachable" : "Open CadenceCore on Watch", systemImage: "applewatch")
                        Button(watch.staging ? "Preparing ride…" : "Prepare ride on Watch", systemImage: "applewatch") { confirmWatch = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(ftp == nil || trainer.workoutOwnsTrainer || trainer.sequenceActive || watch.coordinatedID != nil || watch.staging)
                        Text(watch.status).font(.subheadline)
                        if let staged = watch.staged {
                            Label(watch.stageDelivered ? "Ready on Watch: \(staged.name)" : "Waiting for delivery: \(staged.name)",
                                  systemImage: watch.stageDelivered ? "checkmark.circle" : "clock")
                                .font(.caption)
                            Text("Prepared with FTP \(Int(staged.ftp)) W. Prepare again to apply FTP or simulation changes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let settings = trainer.simulationSettings {
                            Text("Simulated flat-road speed/distance enabled · \(settings.riderMass.formatted()) kg rider. Health inclusion \(settings.saveToHealth ? "on" : "off"); frozen when sent to Watch.")
                                .font(.caption)
                        } else {
                            Text("Set up simulated speed/distance in Settings (optional).").font(.caption)
                        }
                        if let issue = trainer.simulationError { Text(issue).font(.caption).foregroundStyle(.red) }
                        DisclosureGroup("Ride without Watch recording") {
                            Text("No Health save or Watch controls. Use only if you intentionally want an unsaved ride.").font(.caption)
                            Button(localStarting ? "Preparing…" : "Start iPhone-only ride", systemImage: "play.fill") { confirmStart = true }
                                .disabled(ftp == nil || trainer.workoutOwnsTrainer || trainer.sequenceActive || watch.coordinatedID != nil || localStarting || watch.staging)
                        }
                        Text(trainer.playbackStatus).font(.caption)
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
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(isPresented: $showingRide) { RideView(trainer: trainer, watch: watch) }
            .onChange(of: trainer.playbackID) {
                if trainer.workoutOwnsTrainer { showingRide = true }
            }
            .confirmationDialog("Send this workout to Watch?", isPresented: $confirmWatch, titleVisibility: .visible) {
                Button("Send to Watch") {
                    guard var workout, let ftp else { return }
                    workout.name = saved.name
                    Task { await watch.stage(workout, ftp: ftp) }
                }
            } message: {
                Text("Review import warnings first. Start on Watch after delivery. Watch records one indoor cycling workout to Health; iPhone must remain connected to the trainer.")
            }
            .confirmationDialog("Start this ERG workout?", isPresented: $confirmStart, titleVisibility: .visible) {
                Button("Start workout") {
                    guard var workout, let ftp else { return }
                    workout.name = saved.name
                    let selected = workout
                    localStarting = true
                    Task {
                        defer { localStarting = false }
                        guard await trainer.prepareForRide() else {
                            errorMessage = trainer.preparationError
                            return
                        }
                        trainer.startWorkout(selected, ftp: ftp, simulation: trainer.simulationSettings)
                        showingRide = trainer.workoutOwnsTrainer
                    }
                }
            } message: {
                Text("iPhone-only ride: no Health save or Watch controls. Use Send to Watch instead for recording. Trainer resistance follows the imported intervals; pause/finish requests reduced load, not zero resistance.")
            }
            .toolbar {
                Menu {
                    Button("Rename") { editingName = saved.name; renaming = true }
                    NavigationLink("Simulation setup") { SimulationSettingsView(trainer: trainer) }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Workout options") }
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
struct RideView: View {
    @Bindable var trainer: TrainerDiagnostic
    @Bindable var watch: WatchMirror
    @State private var confirmFinish = false
    @State private var confirmRelease = false

    var body: some View {
        List {
            if let playback = trainer.playback {
                Section {
                    Text(playback.workout.name).font(.title2.bold())
                    Text(trainer.playbackStatus)
                    LabeledContent("Workout state", value: playback.state.title)
                    LabeledContent("Active time", value: "\(Int(playback.elapsed) / 60):\(String(format: "%02d", Int(playback.elapsed) % 60))")
                    if let position = playback.position {
                        LabeledContent("Interval", value: "\(position.index + 1) of \(playback.workout.intervals.count)")
                        LabeledContent("Interval remaining", value: "\(Int(ceil(position.remaining))) sec")
                        LabeledContent("Scheduled target", value: "\(position.targetWatts) W")
                        if let cadence = position.cadence {
                            LabeledContent("Workout cadence", value: "\(Int(cadence)) rpm")
                        }
                    }
                    LabeledContent("FTP snapshot", value: "\(Int(playback.ftp)) W")
                }
                Section("Live measurements") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let fresh = trainer.telemetryDate.map { context.date.timeIntervalSince($0) <= 3 } ?? false
                        LabeledContent("Measured power", value: fresh ? trainer.power.map { "\($0) W" } ?? "Unavailable" : "Unavailable / stale")
                        LabeledContent("Cadence", value: fresh ? trainer.cadence.map { "\(Int($0.rounded())) rpm" } ?? "Unavailable" : "Unavailable / stale")
                        let hrFresh = watch.receivedAt.map { context.date.timeIntervalSince($0) <= 10 } ?? false
                        LabeledContent("Heart rate", value: hrFresh ? watch.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "Unavailable" : "Unavailable / stale")
                    }
                }
                Section("Ride controls") {
                    if playback.state == .running {
                        Button("Pause and reduce load", systemImage: "pause.fill") { trainer.pauseWorkout() }
                            .frame(minHeight: 44)
                    }
                    if [.paused, .interrupted].contains(playback.state), playback.position != nil {
                        Button("Resume workout", systemImage: "play.fill") { watch.resumeRide() }
                            .disabled(trainer.pending || trainer.stopFlow.isInProgress || !trainer.hasControl)
                            .frame(minHeight: 44)
                        if !trainer.readyToRide { TrainerSetupView(trainer: trainer) }
                    }
                    if playback.state != .completed {
                        Button("Finish workout", role: .destructive) { confirmFinish = true }
                            .disabled(playback.state == .finishing)
                            .frame(minHeight: 44)
                    }
                    Text(trainer.stopStatus).font(.footnote)
                    Text(watch.status).font(.footnote)
                    if playback.state == .completed, watch.coordinatedID != nil {
                        Button("Release Watch coordination") { confirmRelease = true }
                            .font(.footnote)
                    }
                    Text(watch.isWatchRide
                         ? "Watch saves the workout after confirmed finish. Keep both apps running. Force-quitting can leave the trainer's last target active."
                         : "iPhone-only playback does not save to Health. Watch HR diagnostics must be ended separately on Watch. Force-quitting can leave the trainer's last target active.")
                        .font(.footnote)
                }
                if let simulation = trainer.simulation {
                    Section("Simulated flat-road travel") {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let fresh = playback.state == .running &&
                                (simulation.metrics.date.map { context.date.timeIntervalSince($0) <= 3 } ?? false)
                            LabeledContent("Simulated speed", value: fresh
                                ? simulation.metrics.speed.map { "\(($0 * 3.6).formatted(.number.precision(.fractionLength(1)))) km/h" } ?? "Unavailable"
                                : "Unavailable / paused")
                            LabeledContent("Simulated distance", value: "\((simulation.metrics.distance / 1000).formatted(.number.precision(.fractionLength(2)))) km")
                        }
                        Text("Model v\(simulation.configuration.version) · rider \(simulation.configuration.riderMass.formatted()) kg · bike \(simulation.configuration.bikeMass.formatted()) kg. Estimates, not actual travel.")
                            .font(.footnote)
                        if let issue = trainer.simulationError { Text(issue).foregroundStyle(.red) }
                    }
                }
            }
        }
        .monospacedDigit()
        .navigationTitle("Ride")
        .confirmationDialog("Finish and request reduced load?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Finish workout", role: .destructive) { trainer.finishWorkout() }
        } message: {
            Text("Progression ends and the app requests 0 W followed by stop. This does not guarantee zero resistance.")
        }
        .confirmationDialog("Release without a Health save receipt?", isPresented: $confirmRelease, titleVisibility: .visible) {
            Button("Release coordination", role: .destructive) { watch.releaseFinishedCoordination() }
        } message: {
            Text("Use only if the Watch save result cannot arrive. This does not confirm a Health save or end a Watch recording. End any active session on Watch before starting another.")
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
                Text("Use Workouts for ERG playback. Reduced-load stop requests 0 W before FTMS stop. Neither acknowledgment nor disconnect guarantees zero resistance.")
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
                        .disabled(trainer.workoutOwnsTrainer)
                    Button("Send target power") { confirmTarget = true }
                        .disabled(trainer.workoutOwnsTrainer || trainer.sequenceActive || trainer.stopFlow.isInProgress || !trainer.hasControl || trainer.pending || !(trainer.powerRange?.contains(watts) ?? false))
                    Button("Send start / resume") { trainer.startTrainer() }
                        .disabled(trainer.workoutOwnsTrainer || trainer.sequenceActive || trainer.stopFlow.isInProgress || !trainer.hasControl || trainer.pending)
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
                    .disabled(trainer.workoutOwnsTrainer || trainer.sequenceActive || trainer.stopFlow.isInProgress)
                    Button(trainer.sequenceActive ? "Diagnostic running" : "Arm \(trainer.testLength.rawValue)-minute background test") {
                        confirmSequence = true
                    }
                    .disabled(trainer.workoutOwnsTrainer || trainer.sequenceActive || trainer.stopFlow.isInProgress || !trainer.hasControl || !trainer.trainerRunning || trainer.pending)
                    if trainer.workoutOwnsTrainer {
                        Text("Workout playback owns the trainer. Use ride controls in Workouts; reduced-load stop remains available here.")
                            .font(.footnote)
                    }
                    Button("Disconnect (does not release load)", role: .destructive) { trainer.disconnect() }
                }
            }
            Section("Apple Watch heart rate") {
                Text(watch.status)
                Button("Prepare Watch connection") { Task { await watch.prepare() } }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = watch.receivedAt.map { context.date.timeIntervalSince($0) <= 10 } ?? false
                    LabeledContent("Heart rate", value: fresh ? watch.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "Unavailable" : "Unavailable / stale")
                }
                Text("Watch-started workouts save to Health. HR-only diagnostics are discarded.")
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
