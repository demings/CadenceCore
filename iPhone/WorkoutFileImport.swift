import Foundation

enum WorkoutFileImport {
    static func read(_ url: URL) throws -> (workout: Workout, source: Data) {
        guard url.isFileURL, url.pathExtension.lowercased() == "zwo" else {
            throw WorkoutImportError.invalid("choose a local .zwo workout file.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        let data: Data
        do {
            data = try handle.read(upToCount: ZWOImporter.maximumFileBytes + 1) ?? Data()
        } catch {
            try handle.close()
            throw error
        }
        try handle.close()
        return (try ZWOImporter.parse(data), data)
    }
}
