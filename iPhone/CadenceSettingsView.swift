import Foundation
import Observation
import SwiftUI

@MainActor @Observable
public final class CadenceSettingsController {
    public static let storageKey = "CadenceCore.cadenceConfiguration.v1"
    public private(set) var configuration: CadenceConfiguration
    public private(set) var persistenceError: String?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                configuration = try JSONDecoder().decode(CadenceConfiguration.self, from: data)
            } catch {
                configuration = .init(enabled: false)
                persistenceError = "Saved cadence settings were invalid; guidance is disabled until you save settings or restore defaults."
            }
        } else {
            configuration = .defaults
        }
    }

    /// Copy this value when staging a ride; subsequent edits do not mutate the ride policy.
    public func snapshot() -> CadenceConfiguration { configuration }

    public func save(_ configuration: CadenceConfiguration) throws {
        guard configuration.isValid else {
            throw CadenceGuidanceError.invalidConfiguration
        }
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: Self.storageKey)
        self.configuration = configuration
        persistenceError = nil
    }

    public func restoreDefaults() throws { try save(.defaults) }
}

public struct CadenceSettingsView: View {
    @Bindable private var controller: CadenceSettingsController
    @State private var enabled = true
    @State private var haptics = false
    @State private var values = ["75", "90", "80", "95", "85", "100"]
    @State private var error: String?
    @State private var saved = false
    @FocusState private var focused: Bool

    public init(controller: CadenceSettingsController) {
        self.controller = controller
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Cadence guidance", isOn: $enabled)
                Toggle("Gentle Watch cadence haptics", isOn: $haptics)
                Text("Advisory suggestions, not an optimal cadence or a power-control instruction. Never force a cadence; ERG watts are unchanged.")
                    .font(.footnote)
                Text("Workout cadence targets take priority, including low-cadence drills. Single-rpm targets use ±5 rpm feedback tolerance.")
                    .font(.footnote)
                if let issue = controller.persistenceError { Text(issue).foregroundStyle(.red) }
            }
            Section("Suggested ranges by commanded target / FTP") {
                range("Up to 75% FTP", indices: 0...1)
                range("Above 75%, up to 100% FTP", indices: 2...3)
                range("Above 100% FTP", indices: 4...5)
                Text("Positive lower and upper values, lower below upper, maximum 250 rpm. Broad editable heuristics, not a physiological optimum.")
                    .font(.footnote)
            }
            Section("Feedback timing") {
                Text("Cadence is smoothed over three seconds. Ten-second grace after start, resume, interval or recommendation changes. Haptics require ten continuous seconds outside the range, at most once every 30 seconds. Two-rpm recovery hysteresis reduces flicker.")
                Text("Missing/stale cadence, pauses, disconnection and stopped pedaling suppress guidance. Haptics are off by default.")
            }
            Section {
                Button("Save cadence settings") { save() }
                Button("Restore defaults") {
                    do { try controller.restoreDefaults(); load(); saved = true }
                    catch { self.error = error.localizedDescription }
                }
                Text(saved ? "Saved. Applies when preparing the next ride." : "Changes apply to the next ride, not the current ride snapshot.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cadence guidance")
        .scrollDismissesKeyboard(.interactively)
        .task { load() }
        .onChange(of: values) { saved = false }
        .onChange(of: enabled) { saved = false }
        .onChange(of: haptics) { saved = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .alert("Cadence settings", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func range(_ title: String, indices: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            HStack {
                TextField("Lower rpm", text: $values[indices.lowerBound])
                    .accessibilityLabel("\(title) lower rpm")
                Text("–")
                TextField("Upper rpm", text: $values[indices.upperBound])
                    .accessibilityLabel("\(title) upper rpm")
                Text("rpm")
            }
            .keyboardType(.decimalPad)
            .focused($focused)
        }
    }

    private func load() {
        let configuration = controller.configuration
        enabled = configuration.enabled
        haptics = configuration.hapticsEnabled
        values = [configuration.easy.lower, configuration.easy.upper,
                  configuration.moderate.lower, configuration.moderate.upper,
                  configuration.hard.lower, configuration.hard.upper].map { String($0) }
    }

    private func save() {
        focused = false
        let numbers = values.compactMap {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
        }
        guard numbers.count == 6 else { error = "Enter all six rpm values."; return }
        do {
            try controller.save(.init(enabled: enabled, hapticsEnabled: haptics,
                easy: .init(lower: numbers[0], upper: numbers[1]),
                moderate: .init(lower: numbers[2], upper: numbers[3]),
                hard: .init(lower: numbers[4], upper: numbers[5])))
            saved = true
        } catch { self.error = error.localizedDescription }
    }
}
