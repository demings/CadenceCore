import Testing
@testable import TrainerProtocol

@Test func stopRequiresReducedLoadAcknowledgmentFirst() {
    var flow = ReducedLoadStop()
    #expect(flow.begin(commandPending: false) == .zeroWatts)
    #expect(flow.state == .requestingReducedLoad)
    #expect(flow.isInProgress)
    #expect(flow.commandAcknowledged() == .stop)
    #expect(flow.state == .requestingStop)
    #expect(flow.commandAcknowledged() == nil)
    #expect(flow.state == .completed)
    #expect(!flow.isInProgress)
    #expect(flow.commandAcknowledged() == nil)
}

@Test func stopWaitsForExistingCommandAndIgnoresRepeatedRequests() {
    var flow = ReducedLoadStop()
    #expect(flow.begin(commandPending: true) == nil)
    #expect(flow.state == .waitingForPendingCommand)
    #expect(flow.begin(commandPending: false) == nil)
    #expect(flow.state == .waitingForPendingCommand)
    #expect(flow.commandAcknowledged() == .zeroWatts)
    #expect(flow.begin(commandPending: false) == nil)
    #expect(flow.commandAcknowledged() == .stop)
    #expect(flow.begin(commandPending: false) == nil)
    #expect(flow.commandAcknowledged() == nil)
    #expect(flow.state == .completed)
}

@Test func failureNeverAdvancesToStopOrCompletion() {
    for pending in [false, true] {
        var flow = ReducedLoadStop()
        _ = flow.begin(commandPending: pending)
        flow.fail()
        #expect(flow.state == .failed)
        #expect(flow.commandAcknowledged() == nil)
        #expect(!flow.isInProgress)
        #expect(flow.begin(commandPending: false) == .zeroWatts)
    }
    var flow = ReducedLoadStop()
    _ = flow.begin(commandPending: false)
    _ = flow.commandAcknowledged()
    flow.fail()
    #expect(flow.commandAcknowledged() == nil)
    #expect(flow.state == .failed)
}
