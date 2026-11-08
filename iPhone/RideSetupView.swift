import SwiftUI

struct TrainerSetupView: View {
    @Bindable var trainer: TrainerDiagnostic

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Label(
                trainer.readyToRide ? "Trainer ready" : "Trainer setup",
                systemImage: trainer.readyToRide ? "checkmark.circle.fill" : "bicycle"
            )
            .foregroundStyle(trainer.readyToRide ? Color.teal : Color.primary)
            if let name = trainer.selectedTrainerName { Text(name).font(.subheadline) }
            Text(trainer.status).font(.caption).foregroundStyle(.secondary)
            if let error = trainer.preparationError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if !trainer.connected {
                Button(
                    trainer.isConnecting
                        ? "Connecting…" : trainer.scanning ? "Searching…" : "Find my trainer",
                    systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    trainer.findTrainer()
                }
                .disabled(trainer.isConnecting || trainer.scanning)
                if trainer.scanning || trainer.isConnecting {
                    Button("Cancel search", role: .cancel) { trainer.cancelSearch() }
                }
                ForEach(trainer.devices) { device in
                    Button(device.name) { trainer.connect(device) }
                        .disabled(trainer.isConnecting)
                }
            } else if !trainer.readyToRide {
                Button(
                    trainer.preparing ? "Preparing…" : "Prepare trainer", systemImage: "checkmark.circle"
                ) {
                    Task { _ = await trainer.prepareForRide(forResume: trainer.workoutOwnsTrainer) }
                }
                .disabled(
                    trainer.preparing || trainer.sequenceActive
                        || (trainer.workoutOwnsTrainer
                            && ![.paused, .interrupted].contains(trainer.playback?.state ?? .ready))
                )
            }
            if trainer.connected, !trainer.workoutOwnsTrainer, !trainer.sequenceActive,
                !trainer.trainerRunning
            {
                Button("Change trainer") { trainer.changeTrainer() }
            }
            Text(
                "Keep the trainer powered on and close other cycling apps. Preparation only requests control; resistance changes after you confirm Start."
            )
            .font(.caption)
        }
    }
}

struct FTPSettingView: View {
    @Bindable var configuration: RideConfiguration
    @FocusState private var focused: Bool

    var body: some View {
        TextField("FTP in watts", text: $configuration.ftpText)
            .keyboardType(.numberPad)
            .focused($focused)
            .accessibilityLabel("Functional threshold power in watts")
        if let value = configuration.ftp {
            Text("Targets use \(Int(value)) W FTP, fixed at ride setup.").font(.caption)
        } else {
            Text("Enter your FTP from 1–2000 W. No default is assumed.")
                .font(.caption).foregroundStyle(.orange)
        }
        if focused { Button("Done") { focused = false } }
    }
}

struct RideHomeView: View {
    @Bindable var trainer: TrainerDiagnostic
    @Bindable var watch: WatchMirror
    @State private var endingRideID: UUID?

    var body: some View {
        if trainer.playback != nil {
            RideView(trainer: trainer, watch: watch)
        } else {
            List {
                Section {
                    Label("Your next ride", systemImage: "bicycle").font(.title2.bold())
                    Text(
                        "Choose a workout in Workouts. Its setup screen connects the trainer and sends the ride to Watch—no diagnostic steps needed."
                    )
                }
                Section("Trainer") { TrainerSetupView(trainer: trainer) }
                if !trainer.archiveStore.recoverableRides.isEmpty {
                    Section("Interrupted rides") {
                        ForEach(trainer.archiveStore.recoverableRides) { ride in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(ride.workout.name).font(.headline)
                                Text(
                                    "\(Int(ride.activeDuration) / 60) min saved · \(ride.recordingMode == .watch ? "Watch recording" : "iPhone-only")"
                                )
                                .font(.caption)
                                Button("Recover this ride") { Task { await trainer.restoreRide(ride.id) } }
                                    .disabled(trainer.preparing)
                                Button("End local checkpoint", role: .destructive) {
                                    endingRideID = ride.id
                                }
                            }
                        }
                        Text(
                            "Recovery never resumes resistance automatically. For Watch rides, reconnect or end the existing recording on Watch; do not create a second Health workout."
                        )
                        .font(.footnote)
                        Text(trainer.playbackStatus).font(.caption)
                    }
                }
                if let staged = watch.staged {
                    Section("On your Watch") {
                        Text(staged.name).font(.headline)
                        Text(watch.status)
                        Label(
                            watch.stageDelivered ? "Delivered" : "Waiting for Watch delivery",
                            systemImage: watch.stageDelivered ? "checkmark.circle" : "clock")
                    }
                }
            }
            .navigationTitle("Ride")
            .confirmationDialog(
                "End this local checkpoint?",
                isPresented: Binding(
                    get: { endingRideID != nil }, set: { if !$0 { endingRideID = nil } }
                ), titleVisibility: .visible
            ) {
                Button("End local checkpoint", role: .destructive) {
                    guard let id = endingRideID, let ride = trainer.archiveStore.ride(id: id) else { return }
                    do {
                        try trainer.archiveStore.finish(id: id, at: Date(), activeElapsed: ride.activeDuration)
                    } catch {
                        trainer.recordWatchFailure("Local checkpoint end failed: \(error.localizedDescription)")
                    }
                    endingRideID = nil
                }
            } message: {
                Text(
                    "This only closes local history. It does not stop trainer resistance or save/end an active Watch recording. Stop pedaling and finish the existing Watch recording separately."
                )
            }
        }
    }
}

struct AppSettingsView: View {
    @Bindable var trainer: TrainerDiagnostic
    @Bindable var watch: WatchMirror

    var body: some View {
        List {
            Section("Training") {
                FTPSettingView(configuration: trainer.configuration)
                NavigationLink("Simulated speed and distance") { SimulationSettingsView(trainer: trainer) }
                NavigationLink("Cadence guidance") {
                    CadenceSettingsView(controller: trainer.configuration.cadence)
                }
            }
            Section("Devices") {
                TrainerSetupView(trainer: trainer)
                Label(
                    watch.watchReachable ? "Watch app reachable" : "Open CadenceCore on Watch",
                    systemImage: "applewatch")
                Text(watch.status).font(.caption)
            }
            Section("Troubleshooting") {
                NavigationLink("Inspect Health recording") { HealthRecordingView() }
                NavigationLink("Diagnostics and exportable log") {
                    DiagnosticView(trainer: trainer, watch: watch)
                }
                Text(
                    "Diagnostics are optional. Watch-started rides save to Health. Export a TCX from History for manual Strava upload; automatic Strava sync is not included."
                )
                .font(.footnote)
                if let error = UserDefaults.standard.string(forKey: "lastWatchSessionError") {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
    }
}
