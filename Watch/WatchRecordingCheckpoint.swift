import Foundation
import Observation

struct WatchRecordingCheckpoint: Codable {
    let ride: RideDescriptor
    let collectionStart: Date?
    let snapshot: RideSnapshot?
    let saveAttempted: Bool
    let receipt: RideMessage?

    func validate() throws {
        guard ride.isValid, snapshot?.isValid ?? true,
            snapshot.map({ $0.elapsed <= ride.duration }) ?? true,
            collectionStart.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 }) ?? true,
            !saveAttempted || collectionStart != nil
        else { throw RideLinkError.invalidMessage }
        if let receipt {
            guard receipt.rideID == ride.id, [.saved, .failure].contains(receipt.action) else {
                throw RideLinkError.invalidMessage
            }
            _ = try RideMessage.decode(JSONEncoder().encode(receipt), allowDelayedReceipt: true)
        }
    }
}

@MainActor @Observable
final class WatchCheckpointStore {
    private(set) var value: WatchRecordingCheckpoint?
    private(set) var error: String?
    private let key = "watchRecordingCheckpoint"

    init() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            guard data.count <= 65536 else { throw RideLinkError.invalidMessage }
            let checkpoint = try JSONDecoder().decode(WatchRecordingCheckpoint.self, from: data)
            try checkpoint.validate()
            value = checkpoint
        } catch {
            self.error = "Watch recovery checkpoint cannot be read: \(error.localizedDescription). Review Health before clearing recovery."
        }
    }

    func save(_ checkpoint: WatchRecordingCheckpoint) -> Bool {
        do {
            try checkpoint.validate()
            let data = try JSONEncoder().encode(checkpoint)
            guard data.count <= 65536 else { throw RideLinkError.invalidMessage }
            UserDefaults.standard.set(data, forKey: key)
            value = checkpoint
            error = nil
            return true
        } catch {
            self.error = "Watch recovery checkpoint could not be saved: \(error.localizedDescription). Keep the app open."
            return false
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        value = nil
        error = nil
    }
}
