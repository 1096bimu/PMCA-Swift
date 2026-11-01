import SwiftUI

struct ContentView: View {
    @ObservedObject var store: CameraStore
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    private let languageNames = [
        "English", "Japanese", "French", "German", "Spanish", "Italian",
        "Portuguese", "Simplified Chinese", "Traditional Chinese", "Arabic", "Korean",
        "Dutch (Nederlands)", "Russian"
    ]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    Section("Language presets") {
                        if store.presets.isEmpty {
                            Text("Read a camera, then save its selection here.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(store.presets) { preset in
                            Button { store.usePreset(preset) } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: store.selectedPreset?.id == preset.id ? "checkmark.circle.fill" : "slider.horizontal.3")
                                        .foregroundStyle(store.selectedPreset?.id == preset.id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(preset.name).fontWeight(.medium).foregroundStyle(.primary)
                                        Text("\(preset.model) · \(preset.enabledCount)/35 enabled")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Export…") { store.exportPreset(preset) }
                                Button("Delete", role: .destructive) { store.deletePreset(preset) }
                            }
                        }
                    }
                    Section("Recovery") {
                        Button("Load backup…", systemImage: "clock.arrow.circlepath") { store.restoreBackup() }
                        Button("Show backups", systemImage: "folder") { store.revealBackups() }
                    }
                }
                .disabled(store.busy)
                Divider()
                HStack {
                    Button("Import preset…", systemImage: "square.and.arrow.down") { store.importPreset() }
                        .disabled(store.busy)
                    Spacer()
                }.padding(14)
            }
            .navigationTitle("PMCA Swift")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        cameraCard
                        if store.selection.count == 35 { languageEditor }
                        else { emptyState }
                        applicationInstaller
                    }.padding(28)
                }
                Divider()
                footer
            }
            .navigationTitle("Camera settings")
            .toolbar {
                ToolbarItemGroup {
                    Button("Activity", systemImage: "text.alignleft") { store.showActivity = true }
                    Button("Save preset", systemImage: "square.and.arrow.up") {
                        store.presetName = store.camera.map { "\($0.model) languages" } ?? "Languages"
                        store.showSavePreset = true
                    }
                    .disabled(store.camera == nil || store.selection.count != 35 || store.busy)
                }
            }
        }
        .frame(minWidth: 990, minHeight: 730)
        .task { await store.checkEngine() }
        .sheet(isPresented: $store.showSavePreset) { saveSheet }
        .sheet(isPresented: $store.showApplyConfirmation) { applySheet }
        .sheet(isPresented: $store.showActivity) { activitySheet }
        .alert("PMCA Swift", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
            Button("Show activity") { store.errorMessage = nil; store.showActivity = true }
            if store.errorMessage?.contains("USB") == true {
                Button("Privacy settings") { store.errorMessage = nil; store.openPrivacySettings() }
            }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var applicationInstaller: some View {
        GroupBox("Install application") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Install a camera-compatible APK using PMCA. Connect one supported Sony camera in MTP or Mass Storage mode.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Label(store.selectedAPK?.lastPathComponent ?? "No APK selected", systemImage: "shippingbox")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose APK…") { store.chooseAPK() }.disabled(store.busy)
                    Button("Install") { store.installApplication() }
                        .disabled(store.busy || store.connected || !store.engineReady || store.selectedAPK == nil)
                }
                if store.connected {
                    Text("Disconnect the settings session above, then reconnect the camera in MTP or Mass Storage mode before installing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 29)).foregroundStyle(.tint)
                    .frame(width: 62, height: 62).background(.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.camera?.model ?? "Connect your Sony camera")
                        .font(.title2.weight(.semibold))
                    if let camera = store.camera {
                        Text("Firmware \(camera.firmware ?? "unknown")  ·  \(camera.region)")
                        Text("Serial \(camera.serial)").font(.caption.monospaced())
                    } else {
                        Text("Read its language selection and capture a reusable preset.")
                    }
                }.foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if store.connected {
                    Button("Disconnect") { store.disconnectCamera() }
                        .disabled(store.busy)
                }
                Button { store.readCamera() } label: {
                    Label(store.camera == nil ? "Read camera" : "Read again", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.large)
                .disabled(store.busy || !store.engineReady)
            }
            Divider()
            HStack {
                Picker("Connection", selection: $store.mode) {
                    ForEach(CameraMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 280).disabled(store.busy || store.connected)
                Spacer()
                Label("USB authorization built in", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(store.mode.guidance).font(.callout).foregroundStyle(.secondary)
            Text("Allow access when macOS asks. The camera leaves normal Mass Storage mode while PMCA is connected. Read and Apply use this special mode until you Disconnect or Quit.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("A small preset. Your preferred languages.").font(.title3.weight(.medium))
            Text("Capture the 35 language bytes from a camera with the menu you want.\nLoad that preset on another camera with the same model and firmware.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Every reading saves a local backup. No language changes happen until you apply them.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 48)
    }

    private var languageEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Language bytes").font(.title2.weight(.semibold))
                    Text(store.selectedPreset.map { "Selection from \($0.name) · \($0.region)" } ?? "Selection from the last camera reading")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.enabledCount) / 35 enabled")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let issue = store.compatibilityIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<35, id: \.self) { index in
                    byteButton(index)
                }
            }
            HStack {
                Label("01 Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
                Label("02 Disabled", systemImage: "circle").foregroundStyle(.secondary)
                Spacer()
                Button("Enable all") { store.selection = Array(repeating: 1, count: 35) }
                Button("Reset selection") { store.resetSelection() }.disabled(store.camera == nil)
            }.font(.caption).disabled(store.busy)
            Text("Slots 1–13 use your identified language names; slots 14–35 are unlabeled. This changes which languages appear in the camera’s menu; it does not choose the active display language. Keep that language enabled.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(store.hex).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Copy", systemImage: "doc.on.doc") { store.copyHex() }.labelStyle(.iconOnly).help("Copy the raw hex bytes")
            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(CameraTweakKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { store.tweakSelection[kind.rawValue] ?? false },
                        set: { store.tweakSelection[kind.rawValue] = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(store.busy || store.camera?.tweaks?[kind.rawValue] == nil)
                    .help(store.camera?.tweaks?[kind.rawValue] == nil ? "Unavailable on this camera" : kind.title)
                }
            }
        }
    }

    private func byteButton(_ index: Int) -> some View {
        let enabled = store.selection[index] == 1
        let changed = store.changedSlots.contains(index)
        let name = languageNames.indices.contains(index) ? languageNames[index] : "Slot \(index + 1)"
        return Button { store.toggle(index) } label: {
            VStack(spacing: 5) {
                HStack {
                    Text(String(format: "%02d", index + 1)).font(.caption2.monospaced())
                    Spacer(minLength: 0)
                    if changed { Circle().fill(Color.orange).frame(width: 5, height: 5) }
                }.foregroundStyle(.secondary)
                Text(name)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 32)
                Text(enabled ? "01" : "02").font(.system(.title3, design: .monospaced).weight(.medium))
                    .foregroundStyle(enabled ? Color.accentColor : .secondary)
            }
            .padding(10).frame(maxWidth: .infinity)
            .background(enabled ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(changed ? Color.orange.opacity(0.7) : Color.clear))
        }
        .buttonStyle(.plain).disabled(store.busy)
        .accessibilityLabel("\(name), slot \(index + 1), \(enabled ? "enabled" : "disabled")\(changed ? ", changed" : "")")
        .help("Property \(String(format: "0x%08X", 0x010d008f + index))")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if store.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: store.engineReady ? "checkmark.shield" : "exclamationmark.circle").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.status).font(.callout)
                if store.busy {
                    Text("Keep the camera connected. Activity details appear when the operation finishes.").font(.caption).foregroundStyle(.secondary)
                } else if store.camera != nil && !store.connected {
                    Text("Click Read again to reconnect before applying.").font(.caption).foregroundStyle(.secondary)
                } else if !store.changedSlots.isEmpty || !store.changedTweaks.isEmpty {
                    Text("\(store.changedSlots.count) language bytes and \(store.changedTweaks.count) other settings changed.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Review & apply…") { store.showApplyConfirmation = true }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.canApply)
        }.padding(18)
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Save language preset").font(.title2.weight(.semibold))
            Text("Save the current 35-byte selection with its source model and firmware.").foregroundStyle(.secondary)
            TextField("Preset name", text: $store.presetName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { store.showSavePreset = false }.keyboardShortcut(.cancelAction)
                Button("Save") { store.savePreset() }.keyboardShortcut(.defaultAction)
                    .disabled(store.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 450)
    }

    private var applySheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Apply camera settings?").font(.title2.weight(.semibold))
            Text("\(store.camera?.model ?? "Camera") · Serial \(store.camera?.serial ?? "")")
            Text("\(store.changedSlots.count) language bytes and \(store.changedTweaks.count) other settings will change. A complete settings backup is saved locally; restore uses only its language bytes.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(store.changedSlots, id: \.self) { index in
                        Text(String(format: "Slot %02d    %02X → %02X", index + 1, store.camera?.languages[index] ?? 0, store.selection[index]))
                            .font(.system(.body, design: .monospaced))
                    }
                    ForEach(store.changedTweaks) { kind in
                        Text("\(kind.title): \(store.tweakSelection[kind.rawValue] == true ? "On" : "Off")")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 190)
            Text("Keep the camera’s current display language enabled. After applying, disconnect and restart the camera to check its settings.")
                .font(.callout)
            HStack {
                Button("Show backups") { store.revealBackups() }
                Spacer()
                Button("Cancel") { store.showApplyConfirmation = false }.keyboardShortcut(.cancelAction)
                Button("Apply to camera") { store.showApplyConfirmation = false; store.applySelection() }
                    .buttonStyle(.borderedProminent).disabled(!store.canApply)
            }
        }.padding(24).frame(width: 540)
    }

    private var activitySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Activity").font(.title2.weight(.semibold))
                Spacer()
                Button("Copy") { store.copyActivity() }
                Button("Done") { store.showActivity = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(store.activity.isEmpty ? "No activity yet." : store.activity)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 740, height: 480)
    }
}
