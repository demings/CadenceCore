import Foundation
import Testing
@testable import TrainerProtocol

private func cadenceTick(_ evaluator: inout CadenceGuidanceEvaluator, _ time: Double,
                         rpm: Double? = 60, watts: Double = 150, explicit: Double? = nil,
                         interval: Int = 0, active: Bool = true, connected: Bool = true,
                         sampleTime: Double? = nil) -> CadenceGuidanceEvaluator.Result {
    evaluator.evaluate(now: time, active: active, connected: connected, intervalIndex: interval,
                       targetWatts: watts, ftp: 200, explicitCadence: explicit,
                       cadence: rpm, sampleTimestamp: sampleTime ?? time)
}

@Test func cadenceConfigurationValidationAndPersistence() throws {
    let defaults = CadenceConfiguration.defaults
    #expect(defaults.enabled)
    #expect(!defaults.hapticsEnabled)
    #expect(try JSONDecoder().decode(CadenceConfiguration.self, from: JSONEncoder().encode(defaults)) == defaults)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any])
    legacy.removeValue(forKey: "hapticsEnabled")
    #expect(try JSONDecoder().decode(CadenceConfiguration.self,
        from: JSONSerialization.data(withJSONObject: legacy)).hapticsEnabled == false)
    for range in [CadenceRange(lower: 0, upper: 90), .init(lower: 90, upper: 90),
                  .init(lower: 100, upper: 90), .init(lower: 90, upper: 251),
                  .init(lower: .nan, upper: 90), .init(lower: 90, upper: .infinity)] {
        let invalid = CadenceConfiguration(easy: range)
        #expect(!invalid.isValid)
        #expect(throws: CadenceGuidanceError.self) { try CadenceGuidanceEvaluator(configuration: invalid) }
    }

    legacy["easy"] = ["lower": 0, "upper": 90]
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(CadenceConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    }
}

@Test func cadenceMirroredResultsValidateAndRoundTrip() throws {
        typealias Result = CadenceGuidanceEvaluator.Result
        typealias Target = CadenceGuidanceEvaluator.Target
        let suggestion = Target(range: .init(lower: 75, upper: 90), source: .suggestedForIntensity)
        let explicit = Target(range: .init(lower: 35, upper: 45), source: .workoutTarget, explicitRPM: 40)
        let valid: [Result] = [
            .init(target: nil, smoothedCadence: nil, status: .unavailable),
            .init(target: suggestion, smoothedCadence: 60, status: .grace),
            .init(target: suggestion, smoothedCadence: 60, status: .increaseCadence, recommendsHaptic: true),
            .init(target: explicit, smoothedCadence: 40, status: .withinRange),
            .init(target: explicit, smoothedCadence: 100, status: .easeCadence, recommendsHaptic: true)
        ]
        for result in valid {
            #expect(result.isValid)
            #expect(try JSONDecoder().decode(Result.self, from: JSONEncoder().encode(result)) == result)
        }
        let invalid: [Result] = [
            .init(target: suggestion, smoothedCadence: 100, status: .increaseCadence),
            .init(target: suggestion, smoothedCadence: 60, status: .easeCadence),
            .init(target: suggestion, smoothedCadence: 60, status: .withinRange),
            .init(target: suggestion, smoothedCadence: 60, status: .unavailable),
            .init(target: nil, smoothedCadence: nil, status: .unavailable, recommendsHaptic: true),
            .init(target: nil, smoothedCadence: 80, status: .withinRange),
            .init(target: suggestion, smoothedCadence: nil, status: .grace),
            .init(target: suggestion, smoothedCadence: 0, status: .withinRange),
            .init(target: suggestion, smoothedCadence: 251, status: .withinRange),
            .init(target: suggestion, smoothedCadence: 80, status: .withinRange, recommendsHaptic: true),
            .init(target: suggestion, smoothedCadence: 80, status: .grace, recommendsHaptic: true),
            .init(target: .init(range: .init(lower: 90, upper: 75), source: .suggestedForIntensity),
                  smoothedCadence: 80, status: .grace),
            .init(target: .init(range: suggestion.range, source: .suggestedForIntensity, explicitRPM: 80),
                  smoothedCadence: 80, status: .grace),
            .init(target: .init(range: suggestion.range, source: .workoutTarget),
                  smoothedCadence: 80, status: .grace),
            .init(target: .init(range: suggestion.range, source: .workoutTarget, explicitRPM: 80),
                  smoothedCadence: 80, status: .grace)
        ]
        for result in invalid {
            #expect(!result.isValid)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(Result.self, from: JSONEncoder().encode(result))
            }
        }
        #expect(!Result(target: suggestion, smoothedCadence: .nan, status: .grace).isValid)
        #expect(!Result(target: suggestion, smoothedCadence: .infinity, status: .grace).isValid)
    }
@Test func cadenceIntensityBoundariesAndExplicitDrills() throws {
    for (watts, lower, upper) in [(0.0, 75.0, 90.0), (150, 75, 90), (150.001, 80, 95),
                                 (200, 80, 95), (200.001, 85, 100)] {
        var evaluator = try CadenceGuidanceEvaluator()
        let target = try #require(cadenceTick(&evaluator, 0, watts: watts).target)
        #expect(target.range == CadenceRange(lower: lower, upper: upper))
        #expect(target.source == .suggestedForIntensity)
    }
    var evaluator = try CadenceGuidanceEvaluator()
    let drill = try #require(cadenceTick(&evaluator, 0, watts: 250, explicit: 40).target)
    #expect(drill.explicitRPM == 40)
    #expect(drill.range == CadenceRange(lower: 35, upper: 45))
    #expect(drill.source == .workoutTarget)
    let changed = cadenceTick(&evaluator, 1, watts: 0, explicit: 120)
    #expect(changed.target?.explicitRPM == 120)
    #expect(changed.status == .grace)
    #expect(cadenceTick(&evaluator, 2, explicit: 0).status == .unavailable)
}

@Test func cadenceGraceDeviationAndHapticRateLimit() throws {
    var evaluator = try CadenceGuidanceEvaluator(configuration: .init(hapticsEnabled: true))
    var alerts: [Int] = []
    for second in 0...80 {
        let result = cadenceTick(&evaluator, Double(second))
        if second < 10 { #expect(result.status == .grace) }
        else { #expect(result.status == .increaseCadence) }
        if result.recommendsHaptic { alerts.append(second) }
    }
    #expect(alerts == [20, 50, 80])
    #expect(!cadenceTick(&evaluator, 80).recommendsHaptic)
    var optOut = try CadenceGuidanceEvaluator()
    for second in 0...30 { #expect(!cadenceTick(&optOut, Double(second)).recommendsHaptic) }
}

@Test func cadenceUsesTimeWeightedThreeSecondSmoothing() throws {
    var evaluator = try CadenceGuidanceEvaluator()
    _ = cadenceTick(&evaluator, 0, rpm: 60)
    _ = cadenceTick(&evaluator, 1, rpm: 90)
    let result = cadenceTick(&evaluator, 3, rpm: 120)
    #expect(result.smoothedCadence == 80)
    #expect(cadenceTick(&evaluator, 3, rpm: 200).smoothedCadence == 80)
    #expect(cadenceTick(&evaluator, 4, rpm: 120).smoothedCadence == 100)
}

@Test func cadenceRecoveryHysteresisAndDirectionChanges() throws {
    var evaluator = try CadenceGuidanceEvaluator()
    for second in 0...10 { _ = cadenceTick(&evaluator, Double(second), rpm: 70) }
    for second in 11...14 { _ = cadenceTick(&evaluator, Double(second), rpm: 76) }
    #expect(cadenceTick(&evaluator, 15, rpm: 76).status == .increaseCadence)
    for second in 16...19 { _ = cadenceTick(&evaluator, Double(second), rpm: 77) }
    #expect(cadenceTick(&evaluator, 20, rpm: 77).status == .withinRange)
    for second in 21...24 { _ = cadenceTick(&evaluator, Double(second), rpm: 100) }
    #expect(cadenceTick(&evaluator, 25, rpm: 100).status == .easeCadence)
    for second in 26...29 { _ = cadenceTick(&evaluator, Double(second), rpm: 89) }
    #expect(cadenceTick(&evaluator, 30, rpm: 89).status == .easeCadence)
    for second in 31...34 { _ = cadenceTick(&evaluator, Double(second), rpm: 88) }
    #expect(cadenceTick(&evaluator, 35, rpm: 88).status == .withinRange)
    for second in 36...39 { _ = cadenceTick(&evaluator, Double(second), rpm: 60) }
    for second in 40...43 { _ = cadenceTick(&evaluator, Double(second), rpm: 100) }
    #expect(cadenceTick(&evaluator, 44, rpm: 100).status == .easeCadence)
}

@Test func cadenceRangeEdgesAreInclusive() throws {
    for rpm in [75.0, 90.0] {
        var evaluator = try CadenceGuidanceEvaluator()
        for second in 0...10 {
            let result = cadenceTick(&evaluator, Double(second), rpm: rpm)
            if second == 10 { #expect(result.status == .withinRange) }
        }
    }
}

@Test func cadenceRampBandDebouncingAndIntervalGrace() throws {
    var evaluator = try CadenceGuidanceEvaluator()
    for second in 0...10 { _ = cadenceTick(&evaluator, Double(second), rpm: 80) }
    #expect(cadenceTick(&evaluator, 11, watts: 151).target?.range.lower == 75)
    _ = cadenceTick(&evaluator, 12, watts: 149)
    _ = cadenceTick(&evaluator, 13, watts: 151)
    _ = cadenceTick(&evaluator, 14, watts: 151)
    _ = cadenceTick(&evaluator, 15, watts: 151)
    let changed = cadenceTick(&evaluator, 16, watts: 151)
    #expect(changed.target?.range.lower == 80)
    #expect(changed.status == .grace)
    for second in 17...25 { #expect(cadenceTick(&evaluator, Double(second), watts: 151).status == .grace) }
    #expect(cadenceTick(&evaluator, 26, watts: 151).status == .increaseCadence)
    let interval = cadenceTick(&evaluator, 27, watts: 250, interval: 1)
    #expect(interval.target?.range.lower == 85)
    #expect(interval.status == .grace)
}

@Test func cadenceSensorAndLifecycleGapsSuppressAndRestartGrace() throws {
    for mode in 0...6 {
        var evaluator = try CadenceGuidanceEvaluator(configuration: .init(hapticsEnabled: true))
        for second in 0...19 { _ = cadenceTick(&evaluator, Double(second)) }
        let suppressed: CadenceGuidanceEvaluator.Result
        switch mode {
        case 0: suppressed = cadenceTick(&evaluator, 20, rpm: nil)
        case 1: suppressed = cadenceTick(&evaluator, 20, rpm: 0)
        case 2: suppressed = cadenceTick(&evaluator, 20, active: false)
        case 3: suppressed = cadenceTick(&evaluator, 20, connected: false)
        case 4: suppressed = cadenceTick(&evaluator, 20, sampleTime: 16.99)
        case 5: suppressed = cadenceTick(&evaluator, 20, rpm: .nan)
        default: suppressed = cadenceTick(&evaluator, 20, sampleTime: 21)
        }
        #expect(suppressed.status == .unavailable)
        #expect(!suppressed.recommendsHaptic)
        for second in 21...30 { #expect(cadenceTick(&evaluator, Double(second)).status == .grace) }
        for second in 31...40 { #expect(!cadenceTick(&evaluator, Double(second)).recommendsHaptic) }
        #expect(cadenceTick(&evaluator, 41).recommendsHaptic)
    }
}

@Test func cadenceRejectsBadTimingAndInputs() throws {
    var evaluator = try CadenceGuidanceEvaluator()
    _ = cadenceTick(&evaluator, 0)
    #expect(cadenceTick(&evaluator, 3, sampleTime: 0).status == .grace)
    #expect(cadenceTick(&evaluator, 3.001, sampleTime: 0).status == .unavailable)
    _ = cadenceTick(&evaluator, 4)
    #expect(cadenceTick(&evaluator, 3.5).status == .unavailable)
    #expect(cadenceTick(&evaluator, .nan).status == .unavailable)
    #expect(cadenceTick(&evaluator, 5, watts: -.infinity).status == .unavailable)
    #expect(evaluator.evaluate(now: 6, active: true, intervalIndex: 0, targetWatts: 100,
        ftp: 0, cadence: 80, sampleTimestamp: 6).status == .unavailable)
    var disabled = try CadenceGuidanceEvaluator(configuration: .init(enabled: false, hapticsEnabled: true))
    #expect(cadenceTick(&disabled, 0).status == .unavailable)
    var gap = try CadenceGuidanceEvaluator()
    for second in 0...15 { _ = cadenceTick(&gap, Double(second)) }
    #expect(cadenceTick(&gap, 19).status == .grace)
}
