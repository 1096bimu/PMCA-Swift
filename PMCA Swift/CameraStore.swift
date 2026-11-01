import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor final class CameraStore: ObservableObject {
    static let shared = CameraStore()
    @Published var mode: CameraMode = .service
    @Published private(set) var camera: CameraSnapshot?
    @Published var selection: [Int] = []
    @Published var tweakSelection: [String: Bool] = [:]
    @Published private(set) var presets: [LanguagePreset] = []
    @Published private(set) var selectedPreset: LanguagePreset?
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var engineReady = false
    @Published private(set) var status = "Checking bundled engine…"
    @Published private(set) var activity = ""
    @Published var errorMessage: String?
    @Published var presetName = ""
    @Published var showSavePreset = false
    @Published var showApplyConfirmation = false
    @Published var showActivity = false
    @Published private(set) var selectedAPK: URL?
    private(set) var lastBackup: URL?
    private var cameraMode: CameraMode?
    private var restoreSerial: String?
    private let fileManager = FileManager.default

    var supportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PMCA Swift", isDirectory: true)
    }
    var backupDirectory: URL { supportDirectory.appendingPathComponent("Backups", isDirectory: true) }
    private var presetDirectory: URL { supportDirectory.appendingPathComponent("Presets", isDirectory: true) }
    var changedSlots: [Int] {
        guard let camera, selection.count == 35 else { return [] }
        return (0..<35).filter { selection[$0] != camera.languages[$0] }
    }
    var changedTweaks: [CameraTweakKind] {
        CameraTweakKind.allCases.filter { kind in
            guard let original = camera?.tweaks?[kind.rawValue], let selected = tweakSelection[kind.rawValue] else { return false }
            return original.enabled != selected
        }
    }
    var enabledCount: Int { selection.filter { $0 == 1 }.count }
    var hex: String { selection.map { String(format: "%02X", $0) }.joined(separator: " ") }
    var compatibilityIssue: String? {
        guard let camera else { return nil }
        if cameraMode != mode { return "Read the camera again before applying in this connection mode." }
        if let restoreSerial, restoreSerial != camera.serial { return "This backup belongs to a different camera. Restore requires the original camera." }
        return selectedPreset?.compatibilityIssue(with: camera)
    }
    var canApply: Bool {
        engineReady && connected && !busy && camera != nil && lastBackup != nil && cameraMode == mode &&
        (!changedSlots.isEmpty || !changedTweaks.isEmpty) && enabledCount > 0 && compatibilityIssue == nil
    }

    init() {
        do {
            for directory in [supportDirectory, backupDirectory, presetDirectory] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            for url in try fileManager.contentsOfDirectory(at: presetDirectory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }) {
                do {
                    let preset = try JSONFiles.decode(LanguagePreset.self, data: Data(contentsOf: url))
                    try preset.validate()
                    presets.append(preset)
                } catch { appendLog("Could not load preset \(url.lastPathComponent): \(error.localizedDescription)") }
            }
            presets.sort { $0.createdAt > $1.createdAt }
        } catch { errorMessage = error.localizedDescription }
    }

    func checkEngine() async {
        guard let executable = EngineRunner.executable, fileManager.isExecutableFile(atPath: executable.path) else {
            status = "Bundled engine is missing"
            errorMessage = "The app is missing PMCAEngine. Rebuild it with the supplied engine packaging script."
            return
        }
        do {
            let response = try await EngineRunner.selfTest(executable: executable)
            engineReady = response.ok
            status = response.ok ? "Ready to read a camera" : "Engine check failed"
            appendLog(response.log ?? "")
            if !response.ok { errorMessage = response.error }
        } catch { status = "Engine check failed"; errorMessage = error.localizedDescription }
    }

    func chooseAPK() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an APK made for a compatible Sony PlayMemories camera."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedAPK = url
    }

    func installApplication() {
        guard !busy, !connected, engineReady, let selectedAPK, let executable = EngineRunner.executable else { return }
        busy = true
        status = "Installing app — follow the camera’s screen and keep it connected…"
        appendLog("\n\(Date().formatted()) — Install \(selectedAPK.lastPathComponent)")
        cameraMode = nil
        lastBackup = nil
        Task {
            defer { busy = false }
            do {
                let response = try await EngineRunner.execute(EngineRequest(operation: "install", mode: mode), executable: executable, apkURL: selectedAPK)
                appendLog(response.log ?? "")
                guard response.ok, let package = response.installedPackage else {
                    throw PMCAError(message: response.error ?? "PMCA did not confirm installation.")
                }
                status = "Installed \(package). Check the camera’s Applications menu."
            } catch {
                status = "Installation was not confirmed — see Activity"
                errorMessage = error.localizedDescription
                appendLog(error.localizedDescription)
            }
        }
    }

    func readCamera() {
        guard !busy, engineReady else { return }
        let operationMode = mode
        // Preserve edits for the same camera, but invalidate writing until a fresh read succeeds.
        let editedCamera = changedSlots.isEmpty ? nil : camera
        let previousCamera = camera
        let pendingTweaks = Dictionary(uniqueKeysWithValues: changedTweaks.compactMap { kind in tweakSelection[kind.rawValue].map { (kind.rawValue, $0) } })
        cameraMode = nil
        lastBackup = nil
        perform(EngineRequest(operation: "read", mode: operationMode)) { snapshot in
            let backup = try self.persistBackup(snapshot, mode: operationMode)
            self.tweakSelection = snapshot.tweaks?.mapValues(\.enabled) ?? [:]
            if previousCamera?.serial == snapshot.serial && previousCamera?.model == snapshot.model {
                for (key, value) in pendingTweaks where snapshot.tweaks?[key] != nil { self.tweakSelection[key] = value }
            }
            self.camera = snapshot
            self.cameraMode = operationMode
            self.lastBackup = backup
            if self.selectedPreset == nil && (editedCamera?.serial != snapshot.serial || editedCamera?.model != snapshot.model) {
                self.selection = snapshot.languages
            }
            self.status = "Connected to \(snapshot.model) in PMCA mode · backup saved"
        }
    }

    func applySelection() {
        guard canApply, let camera, let lastBackup else { return }
        do {
            let saved = try JSONFiles.decode(BackupRecord.self, data: Data(contentsOf: lastBackup))
            try saved.snapshot.validate()
            guard saved.snapshot.fingerprint == camera.fingerprint, saved.snapshot.serial == camera.serial else {
                throw PMCAError(message: "Read the camera again to create a matching backup.")
            }
        } catch { errorMessage = "Cannot verify the saved backup: \(error.localizedDescription)"; return }
        let request = EngineRequest(operation: "apply", mode: mode, languages: selection, expected: camera.expected, preset: selectedPreset,
                                    tweaks: Dictionary(uniqueKeysWithValues: changedTweaks.map { ($0.rawValue, tweakSelection[$0.rawValue]!) }))
        perform(request) { snapshot in
            self.camera = snapshot
            self.selection = snapshot.languages
            self.tweakSelection = snapshot.tweaks?.mapValues(\.enabled) ?? [:]
            self.selectedPreset = nil
            self.restoreSerial = nil
            self.status = "Camera settings applied and verified. Disconnect and restart the camera to check them."
            // Persist the verified result so a later edit also has a matching backup.
            self.lastBackup = try self.persistBackup(snapshot, mode: self.mode)
        }
    }

    private func perform(_ request: EngineRequest, completion: @escaping (CameraSnapshot) throws -> Void) {
        guard let executable = EngineRunner.executable else { return }
        busy = true
        status = connected ? (request.operation == "apply" ? "Checking and applying camera settings…" : "Reading camera settings…") : "Authorize USB access, then follow the camera’s screen…"
        appendLog("\n\(Date().formatted()) — \(request.operation.capitalized), \(request.mode.title)")
        Task {
            defer { busy = false }
            do {
                let response = try await EngineRunner.execute(request, executable: executable)
                appendLog(response.log ?? "")
                connected = response.ok
                guard response.ok, let snapshot = response.snapshot else {
                    let suffix = response.writeAttempted == true
                        ? "\nA write was attempted. Its final state is uncertain; your earlier backup is saved. Read the camera again before deciding whether to restore."
                        : ""
                    throw PMCAError(message: (response.error ?? "The engine did not return camera settings.") + suffix)
                }
                try snapshot.validate()
                try completion(snapshot)
            } catch {
                connected = false
                try? await EngineRunner.disconnect()
                if request.operation == "apply" {
                    // Any failure after dispatch could be a partial write; never retry automatically.
                    cameraMode = nil
                }
                status = "Session ended. Read camera again to continue; your selection is kept."
                errorMessage = error.localizedDescription
                appendLog(error.localizedDescription)
            }
        }
    }

    func disconnectCamera() {
        guard !busy else { return }
        Task { await endSession() }
    }

    func endSession() async {
        busy = true
        status = "Disconnecting camera…"
        do {
            try await EngineRunner.disconnect()
            status = "Disconnected. Reconnect in Mass Storage mode before starting another session."
        } catch {
            errorMessage = error.localizedDescription
            appendLog(error.localizedDescription)
            status = "Session ended — reconnect the camera before reading again"
        }
        connected = false
        cameraMode = nil
        busy = false
    }

    private func persistBackup(_ snapshot: CameraSnapshot, mode: CameraMode) throws -> URL {
        try snapshot.validate()
        let stamp = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        let model = snapshot.model.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let url = backupDirectory.appendingPathComponent("\(stamp)_\(model)_\(UUID().uuidString.prefix(8)).json")
        let data = try JSONFiles.encode(BackupRecord(createdAt: Date(), mode: mode, snapshot: snapshot))
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        guard try Data(contentsOf: url) == data else { throw PMCAError(message: "The backup could not be verified on disk.") }
        appendLog("Backup saved: \(url.lastPathComponent)")
        return url
    }

    func toggle(_ index: Int) {
        guard !busy, selection.indices.contains(index) else { return }
        if selection[index] == 1 && enabledCount == 1 { return }
        selection[index] = selection[index] == 1 ? 2 : 1
    }
    func resetSelection() {
        guard !busy else { return }
        selectedPreset = nil
        restoreSerial = nil
        selection = camera?.languages ?? []
        tweakSelection = camera?.tweaks?.mapValues(\.enabled) ?? [:]
    }
    func usePreset(_ preset: LanguagePreset) {
        guard !busy else { return }
        selectedPreset = preset
        restoreSerial = nil
        selection = preset.languages
    }
    func savePreset() {
        guard !busy, let camera else { return }
        do {
            let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
            // Retain the actual source identity when saving a loaded preset on another target.
            var preset = selectedPreset ?? LanguagePreset(name: trimmed, snapshot: camera, languages: selection)
            if let source = selectedPreset {
                preset = LanguagePreset(id: UUID(), name: trimmed, createdAt: Date(), layout: source.layout,
                                        model: source.model, modelCode: source.modelCode, serial: source.serial,
                                        region: source.region, firmware: source.firmware, languages: selection)
            }
            try persistPreset(preset)
            showSavePreset = false
            presetName = ""
        } catch { errorMessage = error.localizedDescription }
    }
    private func persistPreset(_ preset: LanguagePreset) throws {
        try preset.validate()
        try JSONFiles.encode(preset).write(to: presetDirectory.appendingPathComponent("\(preset.id).json"), options: .atomic)
        presets.removeAll { $0.id == preset.id }
        presets.insert(preset, at: 0)
    }
    func importPreset() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a PMCA language preset. Importing does not change the camera."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try readLimited(url, limit: 128 * 1024)
            var preset = try JSONFiles.decode(LanguagePreset.self, data: data)
            try preset.validate()
            preset.id = UUID()
            try persistPreset(preset)
            usePreset(preset)
        } catch { errorMessage = error.localizedDescription }
    }
    func exportPreset(_ preset: LanguagePreset) {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = preset.name.replacingOccurrences(of: "/", with: "-") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONFiles.encode(preset).write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }
    func deletePreset(_ preset: LanguagePreset) {
        guard !busy else { return }
        do {
            try fileManager.removeItem(at: presetDirectory.appendingPathComponent("\(preset.id).json"))
            presets.removeAll { $0.id == preset.id }
            if selectedPreset?.id == preset.id { resetSelection() }
        } catch { errorMessage = error.localizedDescription }
    }
    func restoreBackup() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = backupDirectory
        panel.message = "Load a saved camera backup. Only its 35 language bytes will be restored when you click Apply."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let record = try JSONFiles.decode(BackupRecord.self, data: readLimited(url, limit: 32 * 1024 * 1024))
            try record.snapshot.validate()
            let preset = LanguagePreset(name: "Backup · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))", snapshot: record.snapshot, languages: record.snapshot.languages)
            usePreset(preset)
            restoreSerial = record.snapshot.serial
        } catch { errorMessage = error.localizedDescription }
    }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
    }
    func revealBackups() { NSWorkspace.shared.open(backupDirectory) }
    func copyHex() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hex, forType: .string) }
    func copyActivity() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(activity, forType: .string) }
    private func readLimited(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw PMCAError(message: "This file is too large for a PMCA preset or backup.") }
        return try Data(contentsOf: url)
    }
    private func appendLog(_ text: String) {
        activity += text + "\n"
        if activity.count > 150000 { activity = String(activity.suffix(150000)) }
    }
}

extension LanguagePreset {
    init(id: UUID, name: String, createdAt: Date, layout: String, model: String, modelCode: String, serial: String, region: String, firmware: String?, languages: [Int]) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.layout = layout
        self.model = model; self.modelCode = modelCode; self.serial = serial
        self.region = region; self.firmware = firmware; self.languages = languages
    }
}
