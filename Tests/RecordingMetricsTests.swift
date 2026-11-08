import Foundation
import Testing
@testable import TrainerProtocol

@Test func totalEnergyRequiresBothActualComponents() {
    let full = RecordingMetrics(averageHeartRate: 120, maximumHeartRate: 150,
                               activeKilocalories: 100, restingKilocalories: 20)
    #expect(full.isValid)
    #expect(full.totalKilocalories == 120)
    let missing = RecordingMetrics(averageHeartRate: nil, maximumHeartRate: nil,
                                  activeKilocalories: 100, restingKilocalories: nil)
    #expect(missing.isValid)
    #expect(missing.totalKilocalories == nil)
    #expect(RecordingMetrics(averageHeartRate: nil, maximumHeartRate: nil,
                            activeKilocalories: 0, restingKilocalories: 0).totalKilocalories == 0)
}

@Test func recordingMetricsRejectInvalidValuesAndInconsistentHeartRate() throws {
    for metrics in [
        RecordingMetrics(averageHeartRate: 151, maximumHeartRate: 150, activeKilocalories: 1, restingKilocalories: 1),
        RecordingMetrics(averageHeartRate: .nan, maximumHeartRate: nil, activeKilocalories: 1, restingKilocalories: 1),
        RecordingMetrics(averageHeartRate: 0, maximumHeartRate: nil, activeKilocalories: 1, restingKilocalories: 1),
        RecordingMetrics(averageHeartRate: 100, maximumHeartRate: 301, activeKilocalories: 1, restingKilocalories: 1),
        RecordingMetrics(averageHeartRate: 100, maximumHeartRate: nil, activeKilocalories: -1, restingKilocalories: 1),
        RecordingMetrics(averageHeartRate: nil, maximumHeartRate: nil, activeKilocalories: 100001, restingKilocalories: 1)
    ] {
        #expect(!metrics.isValid)
        if metrics.averageHeartRate?.isNaN != true {
            let message = RideMessage(rideID: UUID(), action: .heartbeat, recording: metrics)
            #expect(throws: RideLinkError.self) { try RideMessage.decode(JSONEncoder().encode(message)) }
        }
    }
}

@Test func recordingSummarySurvivesLiveAndDelayedSaveReceiptRoundTrip() throws {
    let metrics = RecordingMetrics(averageHeartRate: 120, maximumHeartRate: 150,
                                   activeKilocalories: 100, restingKilocalories: 20)
    for action in [RideAction.heartbeat, .heartRate, .saved] {
        let message = RideMessage(rideID: UUID(), action: action,
            date: action == .saved ? Date().addingTimeInterval(-86400) : Date(),
            bpm: action == .heartRate ? 121 : nil, recording: metrics)
        #expect(try RideMessage.decode(JSONEncoder().encode(message), allowDelayedReceipt: true).recording == metrics)
    }
    let legacy = RideMessage(rideID: UUID(), action: .heartbeat)
    #expect(try RideMessage.decode(JSONEncoder().encode(legacy)).recording == nil)
}

@Test func recordingCoverageUnionsOverlapsAndClipsWithoutBridgingGaps() {
    let start = Date(timeIntervalSince1970: 1000)
    func interval(_ lower: Double, _ upper: Double) -> DateInterval {
        DateInterval(start: start.addingTimeInterval(lower), end: start.addingTimeInterval(upper))
    }

    let bounds = interval(0, 20)
    #expect(RecordingCoverage.seconds([], within: bounds) == 0)
    #expect(RecordingCoverage.seconds([interval(1, 1)], within: bounds) == 0)
    #expect(RecordingCoverage.seconds([interval(10, 15), interval(-5, 5), interval(3, 7),
                                      interval(18, 25), interval(10, 15)], within: bounds) == 14)
    #expect(RecordingCoverage.seconds([interval(-5, -1), interval(21, 30)], within: bounds) == 0)
}

@Test func recordingSampleWindowsBreakOnMissingOrStaleTelemetry() {
    let start = Date()
    func sample(_ date: Date?) -> RideSnapshot {
        RideSnapshot(sequence: 1, state: "running", elapsed: 1, interval: 1, remaining: 10,
                     target: 100, power: 100, cadence: 85, telemetryDate: date, status: "Running")
    }
    var windows = TrainerSampleWindow()
    #expect(windows.take(sample(start), now: start, collectionStart: start) == nil)
    let second = start.addingTimeInterval(1)
    #expect(windows.take(sample(second), now: second, collectionStart: start)?.duration == 1)
    #expect(windows.take(sample(nil), now: second, collectionStart: start) == nil)
    let third = start.addingTimeInterval(2)
    #expect(windows.take(sample(third), now: third, collectionStart: start) == nil)
    #expect(windows.take(sample(third), now: third.addingTimeInterval(4), collectionStart: start) == nil)
    let next = third.addingTimeInterval(1)
    #expect(windows.take(sample(next), now: next, collectionStart: start) == nil)
}
