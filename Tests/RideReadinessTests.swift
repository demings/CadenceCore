import Foundation
import Testing
@testable import TrainerProtocol

@Test func readinessUsesTheSameRequiredConditionsAsRideExecution() {
    let now = Date()
    #expect(TrainerReadiness.issue(connected: true, capabilitiesReady: true, hasControl: true,
                                  busy: false, sampleDate: now, now: now) == nil)
    #expect(TrainerReadiness.issue(connected: false, capabilitiesReady: true, hasControl: true,
                                  busy: false, sampleDate: now, now: now) == .disconnected)
    #expect(TrainerReadiness.issue(connected: true, capabilitiesReady: false, hasControl: true,
                                  busy: false, sampleDate: now, now: now) == .capabilities)
    #expect(TrainerReadiness.issue(connected: true, capabilitiesReady: true, hasControl: false,
                                  busy: false, sampleDate: now, now: now) == .control)
    #expect(TrainerReadiness.issue(connected: true, capabilitiesReady: true, hasControl: true,
                                  busy: true, sampleDate: now, now: now) == .busy)
}

@Test func readinessRequiresFreshRealTelemetryAtExactThreeSecondBoundary() {
    let now = Date()
    for (age, ready) in [(0.0, true), (3, true), (3.001, false), (-0.001, false)] {
        let result = TrainerReadiness.issue(connected: true, capabilitiesReady: true, hasControl: true,
            busy: false, sampleDate: now.addingTimeInterval(-age), now: now)
        #expect((result == nil) == ready)
    }
    #expect(TrainerReadiness.issue(connected: true, capabilitiesReady: true, hasControl: true,
                                  busy: false, sampleDate: nil, now: now) == .telemetry)
}

@Test func sessionFailuresPreserveStageDomainCodeAndActionableNextStep() {
    let error = NSError(domain: "HKErrorDomain", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Could not start session"])
    let message = WatchStartPhase.preparing.failure(error)
    #expect(message.contains("Preparing Watch session"))
    #expect(message.contains("Could not start session"))
    #expect(message.contains("[HKErrorDomain:3]"))
    #expect(message.contains("End any active workout"))
    #expect(message.contains("share this error detail"))
}
