import Foundation
import Observation

@MainActor @Observable
final class RideConfiguration {
    var ftpText: String {
        didSet { defaults.set(ftpText, forKey: "ftpWatts") }
    }
    var ftp: Double? {
        guard let value = Double(ftpText), value.isFinite, (1...2000).contains(value) else { return nil }
        return value
    }
    private(set) var simulation: SimulationConfiguration?
    private(set) var simulationError: String?
    let cadence: CadenceSettingsController
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cadence = CadenceSettingsController(defaults: defaults)
        ftpText = defaults.string(forKey: "ftpWatts") ?? ""
        if let data = defaults.data(forKey: "simulationSettings") {
            do {
                let settings = try JSONDecoder().decode(SimulationConfiguration.self, from: data)
                guard settings.isValid else { throw SimulationError.invalidValues }
                simulation = settings
            } catch {
                simulationError = "Saved simulation settings are invalid: \(error.localizedDescription). Reconfigure before using simulation."
            }
        }
    }

    func saveSimulation(_ settings: SimulationConfiguration?) {
        do {
            if let settings {
                guard settings.isValid else { throw SimulationError.invalidValues }
                defaults.set(try JSONEncoder().encode(settings), forKey: "simulationSettings")
            } else {
                defaults.removeObject(forKey: "simulationSettings")
            }
            simulation = settings
            simulationError = nil
        } catch {
            simulationError = "Simulation settings were not saved: \(error.localizedDescription)"
        }
    }
}
