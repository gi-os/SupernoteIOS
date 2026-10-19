import Foundation

/// How this iPhone / iPad presents itself to the cloud. Each physical device gets its own
/// `equipmentNo`, so the server sees your Nomad, iPhone and iPad mini as three Supernotes.
public struct DeviceIdentity: Codable, Sendable, Hashable {
    public var equipmentNo: String
    public var name: String

    public init(equipmentNo: String, name: String) {
        self.equipmentNo = equipmentNo
        self.name = name
    }

    /// Generates a Supernote-shaped serial (e.g. `SN100B3F9A2C7D41E`). Persist it; never regenerate.
    public static func generate(name: String, prefix: String = "SN100B") -> DeviceIdentity {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).uppercased()
        return DeviceIdentity(equipmentNo: prefix + hex, name: name)
    }
}
