import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum WorkoutImportError: Error, LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Cannot import workout: \(reason)"
        }
    }
}

public enum ZWOImporter {
    public static let maximumFileBytes = 1_048_576
    public static let maximumIntervals = 2000
    public static let maximumDuration: Double = 21_600
    public static let maximumCues = 1000
    public static let maximumCueCharacters = 500

    public static func parse(_ data: Data) throws -> Workout {
        guard !data.isEmpty, data.count <= maximumFileBytes else {
            throw WorkoutImportError.invalid("file must be nonempty and at most 1 MiB.")
        }
        guard let xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw WorkoutImportError.invalid("use UTF-8 XML without DTD/entity declarations.")
        }
        let delegate = WorkoutXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard parsed else {
            throw WorkoutImportError.invalid(parser.parserError?.localizedDescription ?? "Malformed XML.")
        }
        guard delegate.seenRoot, delegate.seenWorkout, !delegate.intervals.isEmpty else {
            throw WorkoutImportError.invalid("expected workout_file with a nonempty workout.")
        }
        let name = delegate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WorkoutImportError.invalid("workout name is missing.") }
        return Workout(name: name, description: delegate.details.trimmingCharacters(in: .whitespacesAndNewlines),
                       intervals: delegate.intervals, warnings: delegate.warnings,
                       cues: delegate.cues.isEmpty ? nil : delegate.cues.sorted { $0.offset < $1.offset })
    }
}

private final class WorkoutXMLDelegate: NSObject, XMLParserDelegate {
    var failure: WorkoutImportError?
    var intervals: [WorkoutInterval] = []
    var name = ""
    var details = ""
    var warnings: [String] = []
    var cues: [WorkoutTextCue] = []
    var seenRoot = false
    var seenWorkout = false
    private var stack: [String] = []
    private var duration: Double = 0
    private var blockStart: Double = 0
    private var blockDuration: Double = 0
    private let blocks: Set<String> = ["SteadyState", "Warmup", "Cooldown", "Ramp", "IntervalsT"]

    private func reject(_ parser: XMLParser, _ reason: String) {
        if failure == nil { failure = .invalid(reason) }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        guard failure == nil else { return }
        let parent = stack.last
        stack.append(elementName)
        guard stack.count <= 16 else { reject(parser, "XML nesting exceeds 16 levels."); return }
        do {
            if stack.count == 1 {
                guard elementName == "workout_file", !seenRoot else {
                    throw WorkoutImportError.invalid("root must be workout_file.")
                }
                seenRoot = true
            } else if parent == "workout_file", elementName == "workout" {
                guard !seenWorkout else { throw WorkoutImportError.invalid("multiple workout sections are not supported.") }
                seenWorkout = true
            } else if parent == "workout" {
                guard blocks.contains(elementName) else {
                    throw WorkoutImportError.invalid("unsupported executable block \(elementName).")
                }
                blockStart = duration
                try addBlock(elementName, attributes: attributes)
                blockDuration = duration - blockStart
            } else if let parent, blocks.contains(parent) {
                guard elementName == "textevent" else {
                    throw WorkoutImportError.invalid("unsupported nested instruction \(elementName) in \(parent).")
                }
                try addCue(attributes)
            } else if stack.contains("workout") {
                throw WorkoutImportError.invalid("unsupported nested workout element \(elementName).")
            } else if parent == "workout_file" {
                let known: Set<String> = ["name", "description", "sportType", "author", "tags", "category", "subcategory"]
                if !known.contains(elementName) { warn("Metadata \(elementName) was ignored.") }
            }
        } catch let error as WorkoutImportError {
            if failure == nil { failure = error }
            parser.abortParsing()
        } catch {
            reject(parser, error.localizedDescription)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if stack.contains("workout") && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reject(parser, "workout instructions must use supported elements and attributes, not text content.")
            return
        }
        if stack == ["workout_file", "name"] { name += string }
        if stack == ["workout_file", "description"] { details += string }
        if stack == ["workout_file", "sportType"] { sport += string }
    }

    private var sport = ""

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "sportType" {
            let value = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value != "bike" && value != "cycling" { reject(parser, "only cycling workouts are supported.") }
        }
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        reject(parser, "DTD/entity declarations are not supported.")
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        reject(parser, "external entities are not supported.")
    }

    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
        reject(parser, "DTD declarations are not supported.")
    }

    private func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    private func number(_ attributes: [String: String], _ key: String, range: ClosedRange<Double>) throws -> Double {
        guard let text = attributes[key], let value = Double(text), value.isFinite, range.contains(value) else {
            throw WorkoutImportError.invalid("\(key) must be a finite value in \(range.lowerBound)…\(range.upperBound).")
        }
        return value
    }

    private func cadence(_ attributes: [String: String], _ key: String) throws -> Double? {
        guard attributes[key] != nil else { return nil }
        return try number(attributes, key, range: 1...250)
    }

    private func addCue(_ attributes: [String: String]) throws {
        guard attributes.keys.allSatisfy({ ["timeoffset", "message", "duration"].contains($0) }) else {
            throw WorkoutImportError.invalid("unsupported textevent attribute; text behavior was not guessed.")
        }
        let offset = try number(attributes, "timeoffset", range: 0...blockDuration)
        guard offset < blockDuration else {
            throw WorkoutImportError.invalid("textevent timeoffset must be inside its containing block.")
        }
        let displayDuration = attributes["duration"] == nil ? 5
            : try number(attributes, "duration", range: 0.1...60)
        let cue = WorkoutTextCue(offset: blockStart + offset,
                                 message: attributes["message"] ?? "", duration: displayDuration)
        guard cue.isValid else {
            throw WorkoutImportError.invalid("textevent message must be nonempty, at most 500 characters, without control characters.")
        }
        guard cues.count < ZWOImporter.maximumCues else {
            throw WorkoutImportError.invalid("workout exceeds 1000 text cues.")
        }
        cues.append(cue)
    }

    private func append(_ interval: WorkoutInterval) throws {
        guard intervals.count < ZWOImporter.maximumIntervals else {
            throw WorkoutImportError.invalid("expanded workout exceeds 2000 intervals.")
        }
        guard duration + interval.duration <= ZWOImporter.maximumDuration else {
            throw WorkoutImportError.invalid("workout exceeds six hours.")
        }
        duration += interval.duration
        intervals.append(interval)
    }

    private func addBlock(_ name: String, attributes: [String: String]) throws {
        var supported: Set<String>
        if name == "IntervalsT" {
            supported = ["Repeat", "OnDuration", "OffDuration", "OnPower", "OffPower", "Cadence", "CadenceResting"]
            let repeats = try number(attributes, "Repeat", range: 1...1000)
            guard repeats.rounded(.towardZero) == repeats else {
                throw WorkoutImportError.invalid("Repeat must be an integer.")
            }
            let on = try number(attributes, "OnDuration", range: 0.1...ZWOImporter.maximumDuration)
            let off = try number(attributes, "OffDuration", range: 0.1...ZWOImporter.maximumDuration)
            let onPower = try number(attributes, "OnPower", range: 0...3)
            let offPower = try number(attributes, "OffPower", range: 0...3)
            let onCadence = try cadence(attributes, "Cadence")
            let offCadence = try cadence(attributes, "CadenceResting")
            for _ in 0..<Int(repeats) {
                try append(.init(duration: on, startPower: onPower, endPower: onPower, cadence: onCadence))
                try append(.init(duration: off, startPower: offPower, endPower: offPower, cadence: offCadence))
            }
        } else {
            let duration = try number(attributes, "Duration", range: 0.1...ZWOImporter.maximumDuration)
            let cadence = try cadence(attributes, "Cadence")
            if name == "SteadyState" {
                supported = ["Duration", "Power", "Cadence"]
                let power = try number(attributes, "Power", range: 0...3)
                try append(.init(duration: duration, startPower: power, endPower: power, cadence: cadence))
            } else {
                supported = ["Duration", "PowerLow", "PowerHigh", "Cadence"]
                let start = try number(attributes, "PowerLow", range: 0...3)
                let end = try number(attributes, "PowerHigh", range: 0...3)
                try append(.init(duration: duration, startPower: start, endPower: end, cadence: cadence))
            }
        }
        for key in attributes.keys.sorted() where !supported.contains(key) {
            guard key.lowercased().contains("cadence") else {
                throw WorkoutImportError.invalid("unsupported attribute \(key) in \(name); workout behavior was not guessed.")
            }
            warn("Unsupported \(name) cadence attribute \(key) ignored; supported cadence or intensity guidance will be used.")
        }
    }
}
