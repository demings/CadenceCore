import Charts
import SwiftUI

struct RideHistoryView: View {
    let store: RideArchiveStore
    var activeRideID: UUID? = nil
    @State private var deleting: RideArchive?
    @State private var error: String?

    var body: some View {
        List {
            if let error = error ?? store.error {
                Section { Text(error).foregroundStyle(.red) }
            }
            if store.loaded && store.rides.isEmpty {
                ContentUnavailableView(
                    "No ride history", systemImage: "bicycle",
                    description: Text("Completed and recoverable rides are saved privately on this iPhone."))
            }
            ForEach(store.rides.sorted { $0.startedAt > $1.startedAt }) { ride in
                NavigationLink {
                    RideHistoryDetailView(store: store, rideID: ride.id, activeRideID: activeRideID)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ride.workout.name).font(.headline)
                        Text(ride.startedAt, format: .dateTime.month().day().hour().minute())
                        Text(ride.isRecoverable ? "Unfinished • Recoverable checkpoint" : "Saved on iPhone")
                            .font(.caption).foregroundStyle(ride.isRecoverable ? .orange : .secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { deleting = ride }
                        .disabled(ride.id == activeRideID && ride.isRecoverable)
                }
            }
        }
        .navigationTitle("Ride history")
        .confirmationDialog(
            "Delete this local ride?",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Delete from iPhone", role: .destructive) {
                guard let ride = deleting, !(ride.id == activeRideID && ride.isRecoverable) else { return }
                do { try store.delete(id: ride.id) } catch { self.error = error.localizedDescription }
                deleting = nil
            }
        } message: {
            Text(
                "Deletes local samples and the app's TCX copy. It does not delete an Apple Health workout or a file you shared elsewhere. An unfinished checkpoint cannot then be recovered."
            )
        }
    }
}

private struct RideHistoryDetailView: View {
    let store: RideArchiveStore
    let rideID: UUID
    let activeRideID: UUID?
    @State private var includeSimulation = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var deleting = false
    @State private var showingExport = false
    @State private var loadedConsent = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let ride = store.ride(id: rideID) {
                List {
                    Section("Ride") {
                        Text(ride.workout.name).font(.headline)
                        LabeledContent("Started", value: ride.startedAt.formatted())
                        if let endedAt = ride.endedAt { LabeledContent("Ended", value: endedAt.formatted()) }
                        LabeledContent("Active time", value: duration(ride.activeDuration))
                        LabeledContent("Elapsed time", value: duration(ride.elapsedDuration))
                        LabeledContent("FTP snapshot", value: "\(Int(ride.ftp)) W")
                        if let intensity = ride.initialIntensity {
                            LabeledContent("Initial intensity", value: "\(Int((intensity * 100).rounded()))%")
                        }
                        if let cadence = ride.cadenceConfiguration {
                            LabeledContent("Cadence guidance snapshot", value: cadence.enabled ? "Enabled" : "Disabled")
                            LabeledContent("Cadence haptics snapshot", value: cadence.hapticsEnabled ? "Enabled" : "Disabled")
                        }
                        LabeledContent("Trainer", value: ride.trainer.name)
                        LabeledContent("Recording owner", value: ride.recordingMode == .watch ? "Apple Watch" : "iPhone")
                        if ride.isRecoverable {
                            Text(
                                "Unfinished ride. Resume requires explicit trainer and recording recovery from the ride screen; opening history never restarts ERG or Health recording."
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    Section("Independent save states") {
                        LabeledContent("iPhone", value: "Saved on iPhone")
                        LabeledContent("Apple Health", value: healthStatus(ride.healthReceipt.status))
                        if let detail = ride.healthReceipt.detail { Text(detail).font(.caption) }
                        LabeledContent(
                            "TCX",
                            value: exportURL != nil
                                ? "File ready to share" : ride.isRecoverable ? "Finish before export" : "Ready to export")
                        Text("A file export is not an upload to Strava. Health and iPhone saves are separate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Measured telemetry") {
                        LabeledContent("Samples", value: "\(ride.samples.count)")
                        metric(
                            "Average power", values: ride.samples.compactMap { $0.power.flatMap { $0 >= 0 ? Double($0) : nil } }, unit: "W")
                        metric("Average cadence", values: ride.samples.compactMap(\.cadence), unit: "rpm")
                        metric("Average heart rate", values: ride.samples.compactMap(\.heartRate), unit: "bpm")
                        Text("Averages use available samples only, not targets or missing data. Gaps remain unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let kcal = ride.recordingMetrics?.activeKilocalories {
                            LabeledContent("Health active energy", value: "\(kcal.formatted(.number.precision(.fractionLength(0)))) kcal")
                        } else {
                            Text("Active calories unavailable; not estimated from power.")
                        }
                        if let total = ride.recordingMetrics?.totalKilocalories {
                            LabeledContent("Health total energy", value: "\(total.formatted(.number.precision(.fractionLength(0)))) kcal")
                        }
                        if let average = ride.recordingMetrics?.averageHeartRate {
                            LabeledContent("Health average heart rate", value: "\(Int(average.rounded())) bpm")
                        }
                        if let maximum = ride.recordingMetrics?.maximumHeartRate {
                            LabeledContent("Health maximum heart rate", value: "\(Int(maximum.rounded())) bpm")
                        }
                    }
                    if !ride.samples.isEmpty {
                        Section("Measured samples over elapsed time") {
                            telemetryChart("Power", unit: "W", ride: ride) { sample in
                                sample.power.flatMap { $0 >= 0 ? Double($0) : nil }
                            }
                            telemetryChart("Cadence", unit: "rpm", ride: ride) { $0.cadence }
                            telemetryChart("Heart rate", unit: "bpm", ride: ride) { $0.heartRate }
                            Text(
                                "Dots are recorded measurements, downsampled for display. Missing values and paused periods are not interpolated."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Workout intervals") {
                        ForEach(Array(ride.workout.intervals.enumerated()), id: \.offset) { index, interval in
                            let start = ride.workout.intervals.prefix(index).reduce(0) { $0 + $1.duration }
                            LabeledContent(
                                "Interval \(index + 1)",
                                value: ride.activeDuration >= start + interval.duration
                                    ? "Completed" : ride.activeDuration > start ? "Partial" : "Not reached")
                        }
                        Text("Completion follows active workout time; adjusted ERG targets remain separate from measured power.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Pause and recovery timeline") {
                        ForEach(ride.events, id: \.id) { event in
                            VStack(alignment: .leading) {
                                Text(event.state.rawValue.capitalized)
                                Text("\(event.date.formatted(date: .omitted, time: .standard)) • Active \(duration(event.activeElapsed))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let simulation = ride.simulation {
                        Section("Simulated flat-road estimate") {
                            if let distance = ride.simulatedDistance {
                                LabeledContent(
                                    "Simulated distance", value: "\((distance / 1000).formatted(.number.precision(.fractionLength(2)))) km")
                            }
                            metric("Simulated speed", values: ride.samples.compactMap(\.simulatedSpeed).map { $0 * 3.6 }, unit: "km/h")
                            Text(
                                "Not actual travel or GPS. Model v\(simulation.version), rider \(simulation.riderMass.formatted()) kg, bicycle \(simulation.bikeMass.formatted()) kg, CdA \(simulation.dragArea.formatted()), Crr \(simulation.rollingResistance.formatted()), air density \(simulation.airDensity.formatted()), efficiency \(simulation.efficiency.formatted())."
                            )
                            .font(.caption)
                            Toggle("Include simulated speed/distance in TCX", isOn: simulationInclusion)
                        }
                    }
                    Section("Export for Strava") {
                        Text(
                            "Indoor cycling without GPS. Missing calories and distance use required TCX summary zeros with an explicit unavailable note; missing trackpoint values are omitted. Fitness/Strava may display simulated distance without retaining a prominent label."
                        )
                        .font(.caption)
                        Button("Prepare TCX file", action: prepareExport).disabled(ride.isRecoverable)
                        if let exportURL {
                            ShareLink(item: exportURL) { Label("Share TCX file", systemImage: "square.and.arrow.up") }
                            Text("Manually upload the file using Strava's file upload. Repeated uploads may create duplicates.")
                                .font(.caption)
                        }
                        if let exportError { Text(exportError).foregroundStyle(.red) }
                    }
                    Section {
                        Button("Delete local ride", role: .destructive) { deleting = true }
                            .disabled(ride.id == activeRideID && ride.isRecoverable)
                        if ride.id == activeRideID && ride.isRecoverable {
                            Text("End the active ride before deleting its recovery checkpoint.")
                                .font(.caption)
                        }
                    }
                }
                .onAppear {
                    if !loadedConsent { includeSimulation = ride.simulation?.saveToHealth ?? false; loadedConsent = true }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Export", systemImage: "square.and.arrow.up") { showingExport = true }
                            .disabled(ride.isRecoverable)
                    }
                }
                .sheet(isPresented: $showingExport) {
                    NavigationStack {
                        Form {
                            Section {
                                Text(ride.workout.name).font(.headline)
                                Text("Manual Strava file upload. Exporting does not upload anything or require a successful Health save.")
                                    .font(.callout)
                            }
                            if ride.simulation != nil {
                                Section {
                                    Toggle("Include simulated speed/distance in TCX", isOn: simulationInclusion)
                                    Text("Estimates, not actual travel. Strava may not retain the simulated label.")
                                        .font(.caption)
                                }
                            }
                            Section {
                                Button("Prepare TCX file", action: prepareExport)
                                if let exportURL {
                                    ShareLink(item: exportURL) { Label("Share TCX file", systemImage: "square.and.arrow.up") }
                                }
                                if let exportError { Text(exportError).foregroundStyle(.red) }
                            }
                        }
                        .navigationTitle("Export ride")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingExport = false } } }
                    }
                }
                .onChange(of: includeSimulation) {
                    exportURL = nil
                    exportError = nil
                }
                .confirmationDialog("Delete this local ride?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Delete from iPhone", role: .destructive) {
                        guard !(store.ride(id: rideID)?.isRecoverable == true && rideID == activeRideID) else { return }
                        do {
                            try store.delete(id: rideID)
                            dismiss()
                        } catch { exportError = error.localizedDescription }
                    }
                } message: {
                    Text("Deletes the local checkpoint and app TCX copy, not Apple Health or previously shared files.")
                }
            } else {
                ContentUnavailableView("Ride unavailable", systemImage: "bicycle")
            }
        }
        .navigationTitle("Ride summary")
    }

    private var simulationInclusion: Binding<Bool> {
        Binding(get: { includeSimulation }, set: {
            includeSimulation = $0
            exportURL = nil
            exportError = nil
        })
    }

    private func prepareExport() {
        do {
            exportURL = try store.export(id: rideID, includeSimulation: includeSimulation)
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private func metric(_ name: String, values: [Double], unit: String) -> some View {
        LabeledContent(
            name,
            value: values.isEmpty
                ? "Unavailable" : "\((values.reduce(0, +) / Double(values.count)).formatted(.number.precision(.fractionLength(0)))) \(unit)"
        )
    }
    private func telemetryChart(
        _ name: String, unit: String, ride: RideArchive,
        value: (RideArchiveSample) -> Double?
    ) -> some View {
        let step = max(1, Int(ceil(Double(ride.samples.count) / 600)))
        let points = stride(from: 0, to: ride.samples.count, by: step).compactMap { index -> ChartPoint? in
            let sample = ride.samples[index]
            return value(sample).map { ChartPoint(id: sample.id, elapsed: sample.date.timeIntervalSince(ride.startedAt), value: $0) }
        }
        return VStack(alignment: .leading) {
            Text("\(name) (\(unit))").font(.subheadline)
            if points.isEmpty {
                Text("Unavailable").foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    PointMark(x: .value("Elapsed seconds", point.elapsed), y: .value(name, point.value))
                        .symbolSize(8)
                }
                .chartXScale(domain: 0...max(1, ride.elapsedDuration))
                .frame(height: 110)
                .accessibilityLabel("\(name) recorded samples in \(unit), plotted over elapsed seconds")
            }
        }
    }
    private struct ChartPoint: Identifiable {
        let id: UUID
        let elapsed: Double
        let value: Double
    }
    private func duration(_ seconds: Double) -> String {
        let value = Int(seconds)
        return "\(value / 3600)h \((value % 3600) / 60)m \(value % 60)s"
    }
    private func healthStatus(_ status: RideHealthReceipt.Status) -> String {
        switch status {
        case .pending: "Pending confirmation"
        case .saved: "Saved to Apple Health"
        case .failed: "Not saved — error"
        case .unavailable: "Unavailable"
        }
    }
}
