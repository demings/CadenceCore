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

@Test func shortDiagnosticScheduleBoundaries() {
    #expect(DiagnosticSchedule.Length.short.duration == 240)
    #expect(DiagnosticSchedule.Length.extended.duration == 1200)
    #expect(DiagnosticSchedule.target(at: 0, length: .short) == 80)
    #expect(DiagnosticSchedule.target(at: 59.999, length: .short) == 80)
    #expect(DiagnosticSchedule.target(at: 60, length: .short) == 100)
    #expect(DiagnosticSchedule.target(at: 120, length: .short) == 100)
    #expect(DiagnosticSchedule.target(at: 123, length: .short) == 101)
    #expect(DiagnosticSchedule.target(at: 150, length: .short) == 110)
    #expect(DiagnosticSchedule.target(at: 179.999, length: .short) == 119)
    #expect(DiagnosticSchedule.target(at: 180, length: .short) == 80)
    #expect(DiagnosticSchedule.target(at: 239.999, length: .short) == 80)
    #expect(DiagnosticSchedule.target(at: 240, length: .short) == nil)
    #expect(DiagnosticSchedule.target(at: -1, length: .short) == nil)
    #expect(DiagnosticSchedule.target(at: .nan, length: .short) == nil)
    #expect(DiagnosticSchedule.target(at: .infinity, length: .short) == nil)
}
