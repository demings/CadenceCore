import Foundation
import Testing
@testable import TrainerProtocol

@Test func diagnosticScheduleBoundaries() {
    #expect(DiagnosticSchedule.target(at: 0) == 80)
    #expect(DiagnosticSchedule.target(at: 299.999) == 80)
    #expect(DiagnosticSchedule.target(at: 300) == 100)
    #expect(DiagnosticSchedule.target(at: 600) == 100)
    #expect(DiagnosticSchedule.target(at: 750) == 110)
    #expect(DiagnosticSchedule.target(at: 899.999) == 119)
    #expect(DiagnosticSchedule.target(at: 900) == 80)
    #expect(DiagnosticSchedule.target(at: 1200) == nil)
    #expect(DiagnosticSchedule.target(at: -1) == nil)
    #expect(DiagnosticSchedule.target(at: .nan) == nil)
    #expect(DiagnosticSchedule.target(at: .infinity) == nil)
}
