import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@main
struct CadenceCoreApp: App {
    @State private var trainer: TrainerDiagnostic
    @State private var watch: WatchMirror
    @State private var incomingURL: URL?
    @State private var selectedTab = 0

    init() {
        let trainer = TrainerDiagnostic(
            configuration: RideConfiguration(), archiveStore: RideArchiveStore())
        _trainer = State(initialValue: trainer)
        _watch = State(initialValue: WatchMirror(trainer: trainer))
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    WorkoutLibraryView(trainer: trainer, watch: watch, incomingURL: $incomingURL)
                }
                .tabItem { Label("Workouts", systemImage: "list.bullet.rectangle") }
                .tag(0)
                NavigationStack { RideHomeView(trainer: trainer, watch: watch) }
                    .tabItem { Label("Ride", systemImage: "bicycle") }
                    .tag(1)
                NavigationStack {
                    RideHistoryView(
                        store: trainer.archiveStore,
                        activeRideID: trainer.workoutOwnsTrainer || trainer.archiveError != nil ? trainer.playbackID : nil)
                }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(2)
                NavigationStack { AppSettingsView(trainer: trainer, watch: watch) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(3)
            }
            .tint(.teal)
            .onOpenURL { url in
                selectedTab = 0
                incomingURL = url
            }
        }
        .modelContainer(for: SavedWorkout.self)
    }
}

struct WorkoutLibraryView: View {
    @Bindable var trainer: TrainerDiagnostic
    @Bindable var watch: WatchMirror
    @Binding var incomingURL: URL?
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedWorkout.createdAt, order: .reverse) private var workouts: [SavedWorkout]
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var deleting: SavedWorkout?
    @State private var search = ""
    @State private var favoritesOnly = false

    private var filteredWorkouts: [SavedWorkout] {
        workouts.filter {
            (!favoritesOnly || $0.favorite)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.createdAt > $1.createdAt
        }
    }

    var body: some View {
        List {
            Section {
                Text("Choose a ride. Connect and send to Watch from its setup screen.")
                    .font(.footnote)
                Button("Import ZWO", systemImage: "square.and.arrow.down") {
                    importing = true
                }
                Button("Add original example", systemImage: "plus") {
                    save(.sample, source: nil)
                }
                Menu("More original workouts", systemImage: "bicycle") {
                    Button(Workout.shortCheck.name) { save(.shortCheck, source: nil) }
                    Button(Workout.cadencePractice.name) { save(.cadencePractice, source: nil) }
                }
                Toggle("Favorites only", isOn: $favoritesOnly)
            }
            if trainer.playback != nil {
                Section("Current ride") {
                    NavigationLink("Open ride controls") { RideView(trainer: trainer, watch: watch) }
                }
            }
            Section("Library") {
                if workouts.isEmpty {
                    ContentUnavailableView(
                        "No workouts yet", systemImage: "bicycle",
                        description: Text("Import a cycling ZWO file or add the original example."))
                }
                if !workouts.isEmpty, filteredWorkouts.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(filteredWorkouts) { saved in
                    NavigationLink {
                        WorkoutPreviewView(saved: saved, trainer: trainer, watch: watch)
                    } label: {
                        HStack {
                            if saved.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(saved.name).font(.headline)
                                Text(summary(saved)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
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
        .searchable(text: $search, prompt: "Find a workout")
        .alert(
            "Delete this workout?",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete workout", role: .destructive) {
                guard let deleting else { return }
                context.delete(deleting)
                persist()
                self.deleting = nil
            }
        } message: {
            Text(
                "This removes the library copy. It does not remove an original ZWO file or a workout saved to Health."
            )
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                importFile(try result.get())
            } catch { errorMessage = error.localizedDescription }
        }
        .onChange(of: incomingURL) {
            if let incomingURL {
                importFile(incomingURL)
                self.incomingURL = nil
            }
        }
        .task {
            if let incomingURL {
                importFile(incomingURL)
                self.incomingURL = nil
            }
        }
        .alert(
            "Workout library error",
            isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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

    private func importFile(_ url: URL) {
        do {
            let imported = try WorkoutFileImport.read(url)
            save(imported.workout, source: imported.source)
        } catch { errorMessage = "Workout was not imported: \(error.localizedDescription)" }
    }

    private func persist() {
        do { try context.save() } catch {
            context.rollback()
            errorMessage = "Library change was not saved: \(error.localizedDescription)"
        }
    }
    private func summary(_ saved: SavedWorkout) -> String {
        do {
            let workout = try JSONDecoder().decode(Workout.self, from: saved.encodedWorkout)
            let maximum = workout.intervals.map { max($0.startPower, $0.endPower) }.max() ?? 0
            return
                "\(Int(ceil(workout.duration / 60))) min · \(workout.intervals.count) intervals · up to \(Int((maximum * 100).rounded()))% FTP"
        } catch {
            return "Workout data could not be read. Open to review the error."
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
                ProfilePoint(id: index * 2 + 1, minutes: elapsed / 60, percent: interval.endPower * 100),
            ]
        }
    }

    var body: some View {
        List {
            if let workout {
                Section {
                    Text(workout.description)
                    LabeledContent(
                        "Duration", value: "\(Int(workout.duration / 60)) min \(Int(workout.duration) % 60) sec"
                    )
                    Text(
                        "Start on Watch for heart rate and Health recording. All rides save locally to History."
                    )
                    .font(.footnote)
                }
                Section("1 · Training targets") { FTPSettingView(configuration: trainer.configuration) }
                Section("2 · Trainer") { TrainerSetupView(trainer: trainer) }
                Section("3 · Start your ride") {
                    Label(
                        watch.watchReachable ? "Watch app reachable" : "Open CadenceCore on Watch",
                        systemImage: "applewatch")
                    Button(
                        watch.staging ? "Preparing ride…" : "Prepare ride on Watch", systemImage: "applewatch"
                    ) { confirmWatch = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        ftp == nil || trainer.workoutOwnsTrainer || trainer.sequenceActive
                            || watch.coordinatedID != nil || watch.staging)
                    Text(watch.status).font(.subheadline)
                    if let staged = watch.staged {
                        Label(
                            watch.stageDelivered
                                ? "Ready on Watch: \(staged.name)" : "Waiting for delivery: \(staged.name)",
                            systemImage: watch.stageDelivered ? "checkmark.circle" : "clock"
                        )
                        .font(.caption)
                        Text(
                            "Prepared with FTP \(Int(staged.ftp)) W. Prepare again to apply FTP or simulation changes."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if let settings = trainer.simulationSettings {
                        Text(
                            "Simulated flat-road speed/distance enabled · \(settings.riderMass.formatted()) kg rider. Health inclusion \(settings.saveToHealth ? "on" : "off"); frozen when sent to Watch."
                        )
                        .font(.caption)
                    } else {
                        Text("Set up simulated speed/distance in Settings (optional).").font(.caption)
                    }
                    if let issue = trainer.simulationError {
                        Text(issue).font(.caption).foregroundStyle(.red)
                    }
                    DisclosureGroup("Ride without Watch recording") {
                        Text("Saved locally with TCX export, but no Health save, heart rate or Watch controls.")
                            .font(.caption)
                        Button(
                            localStarting ? "Preparing…" : "Start iPhone-only ride", systemImage: "play.fill"
                        ) { confirmStart = true }
                        .disabled(
                            ftp == nil || trainer.workoutOwnsTrainer || trainer.sequenceActive
                                || watch.coordinatedID != nil || localStarting || watch.staging)
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
                    if let cues = workout.cues, !cues.isEmpty {
                        Section("Workout instructions") {
                            ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                                LabeledContent(
                                    "\(Int(cue.offset) / 60):\(String(format: "%02d", Int(cue.offset) % 60))"
                                ) {
                                    Text(cue.message).multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
                Section("Intervals") {
                    ForEach(Array(workout.intervals.enumerated()), id: \.offset) { index, interval in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                "\(index + 1). \(interval.duration.formatted(.number.precision(.fractionLength(0...1)))) seconds"
                            ).font(.headline)
                            Text(
                                "\(Int((interval.startPower * 100).rounded()))–\(Int((interval.endPower * 100).rounded()))% FTP"
                            )
                            if let ftp {
                                Text(
                                    "\(Int((interval.startPower * ftp).rounded()))–\(Int((interval.endPower * ftp).rounded())) W"
                                )
                            }
                            if let cadence = interval.cadence { Text("Workout cadence: \(Int(cadence)) rpm") }
                        }.monospacedDigit()
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Cannot read workout", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            }
        }
        .navigationTitle(saved.name)
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(isPresented: $showingRide) { RideView(trainer: trainer, watch: watch) }
        .onChange(of: trainer.playbackID) {
            if trainer.workoutOwnsTrainer { showingRide = true }
        }
        .confirmationDialog(
            "Send this workout to Watch?", isPresented: $confirmWatch, titleVisibility: .visible
        ) {
            Button("Send to Watch") {
                guard var workout, let ftp else { return }
                workout.name = saved.name
                Task { await watch.stage(workout, ftp: ftp) }
            }
        } message: {
            Text(
                "Review import warnings first. Start on Watch after delivery. Watch records one indoor cycling workout to Health; iPhone must remain connected to the trainer."
            )
        }
        .confirmationDialog(
            "Start this ERG workout?", isPresented: $confirmStart, titleVisibility: .visible
        ) {
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
            Text(
                "iPhone-only ride: no Health save or Watch controls. Use Send to Watch instead for recording. Trainer resistance follows the imported intervals; pause/finish requests reduced load, not zero resistance."
            )
        }
        .toolbar {
            Menu {
                Button("Rename") {
                    editingName = saved.name
                    renaming = true
                }
                NavigationLink("Simulation setup") { SimulationSettingsView(trainer: trainer) }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Workout options")
            }
        }

        .task {
            do { workout = try JSONDecoder().decode(Workout.self, from: saved.encodedWorkout) } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Rename workout", isPresented: $renaming) {
            TextField("Name", text: $editingName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    errorMessage = "Workout name cannot be empty."
                    return
                }
                saved.name = name
                do { try context.save() } catch {
                    context.rollback()
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "Workout error",
            isPresented: Binding(
                get: { workout != nil && errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
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
                Text(
                    "Use Workouts for ERG playback. Reduced-load stop requests 0 W before FTMS stop. Neither acknowledgment nor disconnect guarantees zero resistance."
                )
                .font(.footnote)
            }
            Section("Trainer") {
                Text(trainer.status)
                if !trainer.connected {
                    Button("Scan for trainer", systemImage: "antenna.radiowaves.left.and.right") {
                        trainer.scan()
                    }
                    ForEach(trainer.devices) { device in
                        Button(device.name) { trainer.connect(device) }
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let fresh =
                            trainer.telemetryDate.map { context.date.timeIntervalSince($0) <= 3 } ?? false
                        LabeledContent(
                            "Measured power",
                            value: fresh
                                ? trainer.power.map { "\($0) W" } ?? "Unavailable" : "Unavailable / stale")
                        LabeledContent(
                            "Cadence",
                            value: fresh
                                ? trainer.cadence.map { "\(Int($0.rounded())) rpm" } ?? "Unavailable"
                                : "Unavailable / stale")
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
                        .disabled(
                            trainer.workoutOwnsTrainer || trainer.sequenceActive || trainer.stopFlow.isInProgress
                                || !trainer.hasControl || trainer.pending
                                || !(trainer.powerRange?.contains(watts) ?? false))
                    Button("Send start / resume") { trainer.startTrainer() }
                        .disabled(
                            trainer.workoutOwnsTrainer || trainer.sequenceActive || trainer.stopFlow.isInProgress
                                || !trainer.hasControl || trainer.pending)
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
                    .disabled(
                        trainer.workoutOwnsTrainer || trainer.sequenceActive || trainer.stopFlow.isInProgress)
                    Button(
                        trainer.sequenceActive
                            ? "Diagnostic running" : "Arm \(trainer.testLength.rawValue)-minute background test"
                    ) {
                        confirmSequence = true
                    }
                    .disabled(
                        trainer.workoutOwnsTrainer || trainer.sequenceActive || trainer.stopFlow.isInProgress
                            || !trainer.hasControl || !trainer.trainerRunning || trainer.pending)
                    if trainer.workoutOwnsTrainer {
                        Text(
                            "Workout playback owns the trainer. Use ride controls in Workouts; reduced-load stop remains available here."
                        )
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
                    LabeledContent(
                        "Heart rate",
                        value: fresh
                            ? watch.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "Unavailable"
                            : "Unavailable / stale")
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
        .confirmationDialog(
            "Send \(watts) W to the trainer?", isPresented: $confirmTarget, titleVisibility: .visible
        ) {
            Button("Send \(watts) W") { trainer.setTarget(watts) }
        } message: {
            Text(
                "ERG resistance may increase as cadence falls. The reduced-load stop requests 0 W but cannot guarantee zero resistance."
            )
        }
        .confirmationDialog(
            "Arm the diagnostic sequence?", isPresented: $confirmSequence, titleVisibility: .visible
        ) {
            Button("Arm \(trainer.testLength.rawValue)-minute sequence") { trainer.beginSequence() }
        } message: {
            Text(
                "First send a target and start the trainer manually. Each stage lasts \(Int(trainer.testLength.stageDuration)) seconds: 80 W, 100 W, a 100–120 W ramp, then 80 W. With ongoing telemetry, completion requests 0 W, waits for acknowledgment, then sends stop. If telemetry or the app stops, the last target may remain active. Logs include measured power/cadence every 15 seconds."
            )
        }
    }
}
