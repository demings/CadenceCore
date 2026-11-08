import SwiftUI

struct SimulationSettingsView: View {
    @Bindable var trainer: TrainerDiagnostic
    @State private var riderMass = ""
    @State private var bikeMass = "10"
    @State private var dragArea = "0.32"
    @State private var rollingResistance = "0.005"
    @State private var airDensity = "1.225"
    @State private var efficiency = "0.97"
    @State private var saveToHealth = true
    @State private var confirmSave = false
    @State private var error: String?
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                Text("Flat-road estimates from measured power. These are not actual travel or trainer flywheel speed, and never change ERG resistance.")
                Text("Set up your mass below; no weight is read from Health. Changes apply the next time you prepare a ride, not to a staged/active ride.")
                    .font(.footnote)
                if let settings = trainer.simulationSettings {
                    Label("Configured · \(settings.riderMass.formatted()) kg rider", systemImage: "checkmark.circle")
                } else {
                    Text("Simulation is off until you confirm setup.").foregroundStyle(.secondary)
                }
                if let issue = trainer.simulationError { Text(issue).foregroundStyle(.red) }
            }
            Section("Mass") {
                field("Rider mass (kg)", text: $riderMass)
                Text("20–300 kg; include clothing if desired.").font(.caption)
                field("Bicycle mass (kg)", text: $bikeMass)
                Text("1–50 kg. Default 10 kg; excludes the stationary trainer.").font(.caption)
            }
            Section("Model assumptions") {
                DisclosureGroup("Advanced flat-road parameters") {
                    field("Drag area CdA (m²)", text: $dragArea)
                    Text("0.1–1 m²; default 0.32. Rider position changes real drag.").font(.caption)
                    field("Rolling resistance coefficient", text: $rollingResistance)
                    Text("0.001–0.03; default 0.005.").font(.caption)
                    field("Air density (kg/m³)", text: $airDensity)
                    Text("0.5–2 kg/m³; default 1.225.").font(.caption)
                    field("Drivetrain efficiency", text: $efficiency)
                    Text("0.5–1; default 0.97.").font(.caption)
                }
                Text("Steady-state flat road; no acceleration, coasting, wind, grade or drafting. Model v1. Distance uses fresh active-ride samples only.")
                    .font(.footnote)
            }
            Section("Health recording") {
                Toggle("Save simulated speed and distance", isOn: $saveToHealth)
                Text("For Watch-started rides only. Health/Fitness may show distance without a prominent simulated label. If off, estimates stay in the live app and are not added to Health.")
                    .font(.footnote)
            }
            Section {
                Button("Save simulation setup") { focused = false; confirmSave = true }
                Button("Turn simulation off", role: .destructive) {
                    focused = false
                    trainer.saveSimulationSettings(nil)
                    saved = trainer.simulationError == nil
                }
                if saved { Text("Saved. Applies to the next ride/staging.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Ride simulation")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .task {
            guard let settings = trainer.simulationSettings else { return }
            riderMass = String(settings.riderMass)
            bikeMass = String(settings.bikeMass)
            dragArea = String(settings.dragArea)
            rollingResistance = String(settings.rollingResistance)
            airDensity = String(settings.airDensity)
            efficiency = String(settings.efficiency)
            saveToHealth = settings.saveToHealth
        }
        .onChange(of: [riderMass, bikeMass, dragArea, rollingResistance, airDensity, efficiency, String(saveToHealth)]) {
            saved = false
        }
        .confirmationDialog("Use this simulated flat-road model?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Confirm and save") { save() }
        } message: {
            Text("Speed/distance are estimates, not actual travel. \(saveToHealth ? "Watch-started rides will include simulated values in Health, which may display them without their simulation label." : "Estimates will not be saved to Health.")")
        }
        .alert("Simulation settings", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text)
                .keyboardType(.decimalPad)
                .focused($focused)
                .accessibilityLabel(label)
        }
    }

    private func number(_ text: String) -> Double? {
        let separator = Locale.current.decimalSeparator ?? "."
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: separator, with: "."))
    }

    private func save() {
        guard let rider = number(riderMass), let bike = number(bikeMass),
              let drag = number(dragArea), let rolling = number(rollingResistance),
              let density = number(airDensity), let efficiency = number(efficiency) else {
            error = "Enter a number for every model value."
            return
        }
        let settings = SimulationConfiguration(riderMass: rider, bikeMass: bike, dragArea: drag,
            rollingResistance: rolling, airDensity: density, efficiency: efficiency, saveToHealth: saveToHealth)
        guard settings.isValid else { error = "Use finite values within the displayed ranges."; return }
        trainer.saveSimulationSettings(settings)
        error = trainer.simulationError
        saved = error == nil
    }
}
