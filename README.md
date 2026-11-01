# PMCA Swift

Native macOS interface for Sony-PMCA-RE: language presets, recording-limit and
PAL/NTSC tweaks, and camera application installation.
This build targets Apple Silicon and macOS 27, matching the original Xcode project
and the bundled runtime's minimum OS. It does not require Homebrew, system Python,
Tk, or a Terminal command on the Mac running the app.

## Use

1. Connect one compatible Sony camera in Mass Storage USB mode; close other apps
   accessing it. Choose Service mode, or Updater mode for a supported older model.
2. Click **Read camera**. macOS asks for administrator authorization when needed.
   Also allow the removable-volume privacy prompt. Full Disk Access may replace
   individual volume toggles in System Settings. Administrator approval alone does
   not replace privacy access. Reading switches the camera into PMCA’s special mode
   and keeps that session open for subsequent Read and Apply requests.
3. Inspect the 35 numbered bytes: `01` enables a slot; `02` disables it. Click a
   slot to toggle it. Slots 1–13 display the language names identified by the user;
   slots 14–35 remain numbered.
4. Below the language flags, check **Disable video recording limit**, **Disable 4K
   video recording limit**, or **Enable PAL / NTSC selector & warning** as desired.
   Unavailable options are disabled. Review & Apply includes changed checkboxes.
   Unchecking uses the original PMCA GUI defaults (29m50s, 5m, selector off).
   Language presets and Load backup continue to affect only language bytes.
5. **Save preset** captures the current editor selection. Import/export uses JSON;
   right-click a saved preset to export or delete it.
6. **Disconnect** before changing cameras or connection modes. Connect and read the
   destination camera, select the desired preset, then **Review & apply**.
   Cross-camera presets require matching model names and known firmware versions.
   Different regional product codes are recorded but do not alone prevent copying.
7. **Disconnect**, then restart the camera and verify the actual language menu. These bytes control
   availability, not the currently selected display language. Keep that language
   enabled. Reading was verified on a DSC-RX1RM2 with firmware 1.00. Language writes,
   menu behavior, and other camera models remain unverified. The persistent session
   has successfully read camera settings during Apply validation.

Every successful reading saves a full camera-settings snapshot in
`~/Library/Application Support/PMCA Swift/Backups`. Backup names include capture time
and model. **Load backup** stages only its language bytes for restoration to the
same camera; it never writes an entire old backup over other settings. **Reset
selection** discards editor changes and returns to the last reading. There is no
automatic restore of regional defaults.

## Install applications

Use **Install application** below the settings editor. Choose a camera-compatible
`.apk` file, then click **Install**. This uses upstream PMCA’s local-APK installer;
it does not browse or download an app catalog. Installation is available without
reading language settings first.

If a settings session is connected, click **Disconnect**, then reconnect the camera
in MTP or Mass Storage mode. Installation uses its own short-lived authorized engine
and PMCA switches the camera to app-install mode. Keep it connected until completion;
the result and upstream log appear in Activity. Cameras without application support
are reported as an unsuccessful install, not a successful no-op.

The selected APK is staged in the private session directory, validated before USB
access, and deleted when the operation finishes. Files are limited to 128 MB.
The startup self-test checks a known AES encryption vector and a complete local
TLS 1.0/AES handshake and data exchange, without accessing the camera. The bundle
includes tlslite source files required by its runtime source-inspection decorators.
APK installation was confirmed working on a DSC-RX1RM2 on November 1, 2026.
Compatibility with other camera models is not established by that test.

## Authorization and packaging

The SwiftUI process stays unprivileged. The first Read starts one bundled helper
through `osascript` and `do shell script … with administrator privileges`.
`launchctl asuser` preserves the logged-in user’s audit session for privacy access.
The helper remains alive inside upstream PMCA’s camera callback, like the original
Python GUI’s tweak dialog. Repeated Read and Apply requests reuse that backend.
Disconnect or normal Quit ends the callback and lets upstream stop service mode.

Requests and responses use length-prefixed JSON over a Unix socket in a randomly
named, owner-only temporary directory. The app verifies the helper’s root peer
identity. The API is limited to read, apply, disconnect, and a staged APK install; there is no arbitrary
shell or file-write API. The helper uses a clean environment and is not an installed
resident service. An app connection loss also unwinds the PMCA session.

The non-sandboxed macOS app and nested helper are code-signed during Xcode builds.
There is no App Store distribution target. A normal macOS authorization prompt is
still required; packaging cannot eliminate camera compatibility, USB ownership,
accessory approval, or hardware/driver limitations. Read/apply are never run at app
startup. The startup self-test checks libraries and local TLS encryption without enumerating cameras.
PMCA’s original USB driver is used without a capture/reattach override. Read/apply
libusb diagnostics are captured in Activity.

A root-owned lock in `/private/var/run/pmca-swift-camera.lock` serializes this app's
camera sessions. Other camera programs must still be closed. The app blocks
normal Quit while a camera operation is running and does not force-kill or retry
writes. Progress is indeterminate; the upstream log appears at operation completion.

## Write safeguards

- Validate exactly 35 values, each 1 or 2, with at least one enabled.
- Validate and durably save the original complete settings backup before enabling
  Apply, and re-check that saved backup immediately before dispatch.
- Re-read the target and require matching identity, firmware, region, and original
  language bytes. Patch this fresh backup so unrelated live camera settings are
  preserved. A changed target or changed language bytes requires a new reading.
  SHA-256 still checks saved-backup integrity; it is not compared across live reads.
- Only edited language properties and explicitly changed recording-limit or
  PAL/NTSC properties are selected for editing. Upstream also manages the
  backup header's protection/checksum fields and temporary read-only attributes.
- Keep upstream checksum handling, attribute restoration, and payload readback.
  Independently verify the resulting 35 language values and changed tweaks after applying.
- Mark uncertain writes as requiring a new reading; do not silently retry/rollback.

A matching model/firmware is a conservative compatibility check, not proof of a
language mapping. Physical-camera validation is still required.

## Build in Xcode

Open `PMCA Swift.xcodeproj` and run the macOS scheme. The prebuilt, self-contained
`Engine/Runtime/PMCAEngine.app` is copied into `Contents/Helpers` by a build phase.
For a different developer account, select your own team under Signing & Capabilities. The bundled engine is arm64, and
the app target is explicitly arm64. Other architectures need a rebuilt runtime.

The Python engine is frozen with PyInstaller in a proper nested .app layout with
its code in Frameworks and data in Resources. Its console entry point preserves
JSON stdout. This avoids Tk entirely and isolates the runtime from Homebrew updates.

To rebuild the engine after changing `Engine/bridge.py`:

```sh
python3 -m venv Engine/.venv
Engine/.venv/bin/pip install -r Engine/requirements.lock
PMCA_BUILD_PYTHON="$PWD/Engine/.venv/bin/python" \
PMCA_LIBUSB="$(brew --prefix libusb)/lib/libusb-1.0.dylib" \
Scripts/build-engine.sh
```

Homebrew Python and libusb are build-time tools only. Build the runtime on the
oldest macOS you intend to support and update both minimum-OS declarations when
producing a broader release. Rebuild bundled libraries when dependencies change;
updating Homebrew alone does not update the app.

Hardened runtime is enabled for the app and the bundled engine. The helper and
its libraries are signed with the same Xcode identity, retaining library validation
without runtime exceptions. Release builds omit the debugger entitlement; Debug
builds retain Xcode debugging support. The helper is timestamped during signing.

Local builds use the configured development team. For distribution outside the
App Store, archive and export with Developer ID signing, then notarize and staple
the app. Enabling hardened runtime alone does not notarize the application.

## Git and Xcode

Clone https://github.com/1096bimu/PMCA-Swift.git and open `PMCA Swift.xcodeproj`.
The shared **PMCA Swift** scheme and prebuilt engine are included. Xcode personal
workspace state and rebuildable intermediates are ignored.

Commit changes on `main` and push to `origin/main` using Xcode’s source-control
commands or Git. After editing the Python bridge, rebuild the engine before
committing so the checked-in runtime matches the source. Camera backups and
presets are stored in Application Support, outside this repository.

## Verification without UI automation

```sh
Engine/.venv/bin/python -m unittest discover -s Tests -p 'test_*.py'
Engine/.venv/bin/python Tests/test_engine.py --export-fixture /tmp/pmca-fixture.json
xcrun swiftc 'PMCA Swift/Models.swift' Tests/ModelTests.swift -o /tmp/pmca-model-tests
/tmp/pmca-model-tests /tmp/pmca-fixture.json
xcodebuild -project 'PMCA Swift.xcodeproj' -scheme 'PMCA Swift' \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PMCASwiftDerivedData build
```

The Python tests use the actual upstream parser/checksum/patch classes with a
simulated camera. Session tests cover repeated Read, Read/Apply/Read, Disconnect,
app connection loss, mode-change rejection, and camera errors. No physical camera is touched by the tests. Build verification
uses command output and bundle inspection, not computer-use or visual inspection.

## Upstream and licenses

Sony-PMCA-RE is vendored unmodified at commit
`a82f5baaa8e9c3d9f28f94699e860fb2e48cc8e0`:
https://github.com/ma1co/Sony-PMCA-RE

Its MIT license and dependency license notices are in `Engine/licenses` and included
in the helper's Resources. Runtime dependency versions are in
`Engine/requirements.lock`. The bridge delegates mode switching, authentication,
backup parsing, and writing to upstream rather than implementing new protocols.

libusb 1.0.30 (LGPL-2.1-or-later): https://github.com/libusb/libusb/releases/tag/v1.0.30
The libusb library is dynamically linked and may be replaced with a compatible
rebuild, followed by re-signing the local bundle. Build scripts and source for this
wrapper are included in the project.
