import Foundation
import CryptoKit

struct PMCAError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum CameraMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case service, updater
    var id: String { rawValue }
    var title: String { self == .service ? "Service mode" : "Updater mode" }
    var guidance: String {
        self == .service
        ? "Connect one camera by USB in Mass Storage mode. Close Photos and other camera apps."
        : "For compatible older models. The camera may restart into updater mode; follow its screen instructions."
    }
}

enum CameraTweakKind: String, CaseIterable, Identifiable {
    case recLimit, recLimit4k, palNtscSelector
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recLimit: return "Disable video recording limit"
        case .recLimit4k: return "Disable 4K video recording limit"
        case .palNtscSelector: return "Enable PAL / NTSC selector & warning"
        }
    }
}

struct CameraTweak: Codable, Equatable, Sendable {
    let enabled: Bool
    let raw: [Int]
}

struct CameraSnapshot: Codable, Sendable {
    let layout: String
    let model: String
    let modelCode: String
    let serial: String
    let region: String
    let firmware: String?
    let languages: [Int]
    let fingerprint: String
    let backupBase64: String
    let engineRevision: String
    var tweaks: [String: CameraTweak]? = nil

    func validate() throws {
        try LanguagePreset.validateBytes(languages)
        guard layout == LanguagePreset.layoutID, !model.isEmpty, !modelCode.isEmpty,
              !serial.isEmpty, !region.isEmpty, fingerprint.count == 64,
              let data = Data(base64Encoded: backupBase64), data.count >= 256 else {
            throw PMCAError(message: "The engine returned an incomplete camera backup.")
        }
        // Sony's backup header stores the validated payload end in these fields.
        func uint32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << (8 * $1)) }
        }
        let end = uint32(0x18) + uint32(0x1c)
        guard end >= 256, end <= data.count else {
            throw PMCAError(message: "The camera backup has an invalid size.")
        }
        let digest = SHA256.hash(data: data.subdata(in: 256..<end)).map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint else {
            throw PMCAError(message: "The camera backup failed its integrity check.")
        }
    }

    var expected: ExpectedCamera {
        ExpectedCamera(model: model, modelCode: modelCode, serial: serial, region: region,
                       firmware: firmware, languages: languages, tweaks: tweaks)
    }
}

struct ExpectedCamera: Codable, Sendable {
    let model: String
    let modelCode: String
    let serial: String
    let region: String
    let firmware: String?
    let languages: [Int]
    var tweaks: [String: CameraTweak]? = nil
}

struct LanguagePreset: Codable, Identifiable, Sendable {
    static let layoutID = "sony-pmca-35-v1"
    var id: UUID
    var name: String
    let createdAt: Date
    let layout: String
    let model: String
    let modelCode: String
    let serial: String
    let region: String
    let firmware: String?
    let languages: [Int]
    var enabledCount: Int { languages.filter { $0 == 1 }.count }

    init(name: String, snapshot: CameraSnapshot, languages: [Int]) {
        id = UUID()
        self.name = name
        createdAt = Date()
        layout = snapshot.layout
        model = snapshot.model
        modelCode = snapshot.modelCode
        serial = snapshot.serial
        region = snapshot.region
        firmware = snapshot.firmware
        self.languages = languages
    }

    static func validateBytes(_ bytes: [Int]) throws {
        guard bytes.count == 35, bytes.allSatisfy({ $0 == 1 || $0 == 2 }), bytes.contains(1) else {
            throw PMCAError(message: "A preset needs exactly 35 bytes: 01 for enabled or 02 for disabled, with at least one enabled.")
        }
    }

    func validate() throws {
        try Self.validateBytes(languages)
        guard layout == Self.layoutID, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 120, !model.isEmpty, !serial.isEmpty else {
            throw PMCAError(message: "This is not a supported PMCA language preset.")
        }
    }

    func compatibilityIssue(with camera: CameraSnapshot) -> String? {
        guard model == camera.model else { return "This preset belongs to \(model), not \(camera.model)." }
        if serial == camera.serial && firmware == camera.firmware { return nil }
        guard let firmware, !firmware.isEmpty, firmware == camera.firmware else {
            return "Copying between cameras requires a matching, known firmware version."
        }
        return nil
    }
}

struct BackupRecord: Codable, Sendable {
    let createdAt: Date
    let mode: CameraMode
    let snapshot: CameraSnapshot
}

struct EngineRequest: Encodable, Sendable {
    let operation: String
    let mode: CameraMode
    var languages: [Int]? = nil
    var expected: ExpectedCamera? = nil
    var preset: LanguagePreset? = nil
    var tweaks: [String: Bool]? = nil
}

struct EngineResponse: Decodable, Sendable {
    let ok: Bool
    let snapshot: CameraSnapshot?
    let error: String?
    let log: String?
    let writeAttempted: Bool?
    var installedPackage: String? = nil
}

enum JSONFiles {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
