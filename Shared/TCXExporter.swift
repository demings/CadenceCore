import Foundation

public struct TCXExportOptions: Sendable {
    /// nil uses the immutable session's confirmed Health/TCX simulation inclusion preference.
    public var includeSimulation: Bool?
    public init(includeSimulation: Bool? = nil) { self.includeSimulation = includeSimulation }
}

public enum TCXExporter {
    public static func xml(for ride: RideArchive, options: TCXExportOptions = .init()) throws
        -> String
    {
        try ride.validate()
        guard ride.endedAt != nil else {
            throw RideArchiveError.invalid("Finish the ride before exporting.")
        }
        guard
            ride.samples.contains(where: {
                ($0.power.map { $0 >= 0 } ?? false) || ($0.cadence.map { $0.rounded() <= 254 } ?? false)
                    || ($0.heartRate.map { $0.rounded() <= 255 } ?? false)
            })
        else {
            throw RideArchiveError.invalid(
                "No measured power, cadence, or heart-rate samples representable in TCX are available.")
        }
        let includeSimulation =
            (options.includeSimulation ?? ride.simulation?.saveToHealth ?? false)
            && ride.simulation != nil
        let distance = includeSimulation ? ride.simulatedDistance : nil
        let calories = ride.recordingMetrics?.activeKilocalories
        guard (calories ?? 0).rounded() <= 65535 else {
            throw RideArchiveError.invalid("Active energy exceeds the TCX unsigned-short calorie field.")
        }
        var notes = [
            "CadenceCore indoor cycling; no GPS coordinates or elevation.",
            "Ride UUID: \(ride.id.uuidString). Repeated manual uploads may create duplicates.",
            "Summary duration is active time, excluding pauses and interruptions.",
            "Power, cadence and heart rate are measured when available; ERG targets are not measurements.",
        ]
        if ride.samples.contains(where: { $0.heartRateSampleDate != nil }) {
            notes.append(
                "Heart rate is a fresh Watch reading aligned once to a trainer trackpoint within 3 seconds. Original reading timestamps remain in local history; no repeated or interpolated heart rate is generated."
            )
        }
        if ride.samples.contains(where: {
            ($0.cadence.map { $0.rounded() > 254 } ?? false)
                || ($0.heartRate.map { $0.rounded() > 255 } ?? false)
        }) {
            notes.append(
                "TCX field limits: cadence above 254 rpm and heart rate above 255 bpm after rounding are omitted, not clamped. Original values remain in local history."
            )
        }
        if ride.samples.contains(where: { ($0.power ?? 0) < 0 }) {
            notes.append(
                "Negative measured power cannot be represented by TCX unsigned watts and is omitted, not replaced with a target."
            )
        }
        if includeSimulation, let settings = ride.simulation {
            notes.append(
                "Speed and distance are simulated flat-road estimates, not actual travel. Model v\(settings.version): rider \(number(settings.riderMass)) kg; bike \(number(settings.bikeMass)) kg; CdA \(number(settings.dragArea)) m2; Crr \(number(settings.rollingResistance)); air density \(number(settings.airDensity)) kg/m3; efficiency \(number(settings.efficiency)). Fitness/Strava may not retain this label."
            )
        } else {
            notes.append("Simulated speed/distance excluded by export option or session consent.")
        }
        // TCXv2 requires Lap DistanceMeters and Calories. Zero is a schema placeholder only;
        // omit unavailable trackpoint values and disclose absence rather than deriving calories.
        if distance == nil {
            notes.append(
                "Distance unavailable: required Lap DistanceMeters=0 is a schema placeholder, not measured distance."
            )
        }
        if calories == nil {
            notes.append(
                "Calories unavailable: required Lap Calories=0 is a schema placeholder, not measured energy. No calories inferred from power."
            )
        } else {
            notes.append(
                "Calories are available Watch/Health active energy, rounded to whole kilocalories.")
        }
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2" xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
            <Activities><Activity Sport="Biking"><Id>\(timestamp(ride.startedAt))</Id>
            <Lap StartTime="\(timestamp(ride.startedAt))"><TotalTimeSeconds>\(number(ride.activeDuration))</TotalTimeSeconds><DistanceMeters>\(number(distance ?? 0))</DistanceMeters><Calories>\(Int((calories ?? 0).rounded()))</Calories><Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod>
            """
        var previous: RideArchiveSample?
        var trackOpen = false
        var eventIndex = 0
        var previousSegment: Int?
        for sample in ride.samples {
            while eventIndex + 1 < ride.events.count && ride.events[eventIndex + 1].date <= sample.date {
                eventIndex += 1
            }
            let newTrack =
                !trackOpen || previousSegment != eventIndex
                || previous.map {
                    sample.date.timeIntervalSince($0.date) > 3 || sample.activeElapsed == $0.activeElapsed
                        || sample.date.timeIntervalSince($0.date) - (sample.activeElapsed - $0.activeElapsed)
                            > 1
                } == true
            if newTrack {
                if trackOpen { xml += "</Track>" }
                xml += "<Track>"
                trackOpen = true
            }
            xml += "<Trackpoint><Time>\(timestamp(sample.date))</Time>"
            if includeSimulation, let meters = sample.simulatedDistance {
                xml += "<DistanceMeters>\(number(meters))</DistanceMeters>"
            }
            if let heartRate = sample.heartRate, heartRate.rounded() <= 255 {
                xml += "<HeartRateBpm><Value>\(Int(heartRate.rounded()))</Value></HeartRateBpm>"
            }
            // TCX cadence is an unsigned byte, unlike FTMS. Omit unrepresentable values.
            if let cadence = sample.cadence, cadence.rounded() <= 254 {
                xml += "<Cadence>\(Int(cadence.rounded()))</Cadence>"
            }
            let speed = includeSimulation ? sample.simulatedSpeed : nil
            let watts = sample.power.flatMap { $0 >= 0 ? $0 : nil }
            if speed != nil || watts != nil {
                xml += "<Extensions><ns3:TPX>"
                if let speed { xml += "<ns3:Speed>\(number(speed))</ns3:Speed>" }
                if let watts { xml += "<ns3:Watts>\(watts)</ns3:Watts>" }
                xml += "</ns3:TPX></Extensions>"
            }
            xml += "</Trackpoint>"
            previous = sample
            previousSegment = eventIndex
        }
        if trackOpen { xml += "</Track>" }
        xml +=
            "</Lap><Notes>\(escape(ride.workout.name + "\n" + notes.joined(separator: "\n")))</Notes></Activity></Activities></TrainingCenterDatabase>"
        return xml
    }

    /// The private export filename and Activity Id are repeatable; no export-time UUID/date is used.
    public static func write(
        _ ride: RideArchive, to directory: URL,
        options: TCXExportOptions = .init()
    ) throws -> URL {
        let data = Data(try xml(for: ride, options: options).utf8)
        let url = directory.appendingPathComponent("CadenceCore-\(ride.id.uuidString).tcx")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS) || os(watchOS)
                try data.write(
                    to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
                try data.write(to: url, options: .atomic)
            #endif
            return url
        } catch { throw RideArchiveError.persistence("TCX export: \(error.localizedDescription)") }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
    private static func escape(_ string: String) -> String {
        let valid = String(
            String.UnicodeScalarView(
                string.unicodeScalars.filter {
                    $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value)
                        || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
                }))
        return valid.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
            of: "<", with: "&lt;"
        )
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
    }
}
