import Foundation

@main struct ModelTests {
    static func main() throws {
        let camera = try JSONDecoder().decode(CameraSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        try camera.validate()
        let preset = LanguagePreset(name: "Test preset", snapshot: camera, languages: camera.languages)
        try preset.validate()
        precondition(preset.compatibilityIssue(with: camera) == nil)
        let roundtrip = try JSONFiles.decode(LanguagePreset.self, data: JSONFiles.encode(preset))
        precondition(roundtrip.languages == preset.languages && roundtrip.id == preset.id)
        let record = BackupRecord(createdAt: Date(), mode: .service, snapshot: camera)
        let restored = try JSONFiles.decode(BackupRecord.self, data: JSONFiles.encode(record))
        try restored.snapshot.validate()
        precondition(restored.snapshot.fingerprint == camera.fingerprint)
        for invalid in [[Int](repeating: 2, count: 35), [1, 2], [Int](repeating: 0, count: 35)] {
            do { try LanguagePreset.validateBytes(invalid); fatalError("Invalid bytes accepted") }
            catch is PMCAError {}
        }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as! [String: Any]
        json["fingerprint"] = String(repeating: "0", count: 64)
        let corrupted = try JSONDecoder().decode(CameraSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        do { try corrupted.validate(); fatalError("Corrupt backup accepted") }
        catch is PMCAError {}
        json["fingerprint"] = camera.fingerprint
        json["model"] = "OTHER"
        let other = try JSONDecoder().decode(CameraSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(preset.compatibilityIssue(with: other) != nil)
        let request = EngineRequest(operation: "apply", mode: .service, languages: preset.languages, expected: camera.expected, preset: preset)
        let encoded = try JSONEncoder().encode(request)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("backupBase64"))
        print("Swift model checks passed: backup integrity, preset/backup roundtrips, byte validation, compatibility, request scope.")
    }
}
