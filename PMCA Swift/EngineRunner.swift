import Foundation
import Darwin

/// One authorized PMCA process owns the connection until Disconnect or Quit.
enum EngineRunner {
    static var executable: URL? {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PMCAEngine.app/Contents/MacOS/pmca-engine")
    }
    private static let queue = DispatchQueue(label: "PMCA session")
    private static let session = CameraSession()

    static func execute(_ request: EngineRequest, executable: URL, apkURL: URL? = nil) async throws -> EngineResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if request.operation == "install" && session.isOpen {
                        throw PMCAError(message: "Disconnect the settings session before installing an app.")
                    }
                    if !session.isOpen { try session.open(executable: executable, apkURL: apkURL) }
                    let response = try session.exchange(JSONEncoder().encode(request))
                    if !response.ok || request.operation == "install" { session.close() }
                    continuation.resume(returning: response)
                } catch {
                    session.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func disconnect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                defer { session.close() }
                do {
                    if session.isOpen {
                        let response = try session.exchange(Data(#"{"operation":"disconnect"}"#.utf8))
                        if !response.ok { throw PMCAError(message: response.error ?? "Could not end the camera session.") }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func selfTest(executable: URL) async throws -> EngineResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = ["--self-test"]
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = output
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw PMCAError(message: String(decoding: data, as: UTF8.self)) }
                    continuation.resume(returning: try JSONDecoder().decode(EngineResponse.self, from: data))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Private local socket: no network listener, shell commands, or camera writes outside the bridge API.
private final class CameraSession {
    private var descriptor: Int32 = -1
    private var process: Process?
    private var directory: URL?
    var isOpen: Bool { descriptor >= 0 }

    func open(executable: URL, apkURL: URL? = nil) throws {
        let folder = URL(fileURLWithPath: "/tmp/pmca-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = folder
        if let apkURL {
            let access = apkURL.startAccessingSecurityScopedResource()
            defer { if access { apkURL.stopAccessingSecurityScopedResource() } }
            let values = try apkURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 128 * 1024 * 1024 else {
                throw PMCAError(message: "Choose an APK file no larger than 128 MB.")
            }
            try FileManager.default.copyItem(at: apkURL, to: folder.appendingPathComponent("application.apk"))
        }
        let path = folder.appendingPathComponent("session.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw failure() }
        defer { Darwin.close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    _ = strcpy(destination, source)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw failure() }
        let script = """
        on run argv
            set commandText to "/bin/launchctl asuser " & quoted form of (item 3 of argv) & " /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_CTYPE=UTF-8 " & quoted form of (item 1 of argv) & " --session " & quoted form of (item 2 of argv)
            return do shell script commandText with administrator privileges
        end run
        """
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        child.arguments = ["-", executable.path, path, String(getuid())]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = output
        // Drain authorization/exit diagnostics without retaining the process or blocking its pipe.
        output.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        try child.run()
        process = child
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 100) > 0 {
                descriptor = accept(listener, nil, nil)
                guard descriptor >= 0 else { throw failure() }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(descriptor, &uid, &gid) == 0, uid == 0 else {
                    throw PMCAError(message: "The camera engine was not authorized as administrator.")
                }
                var noSignal: Int32 = 1
                _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: apkURL == nil ? 180 : 900, tv_usec: 0)
                _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                return
            }
            if !child.isRunning { throw PMCAError(message: "Camera authorization was cancelled or the engine could not start. Click Read to try again.") }
        }
        throw PMCAError(message: "Camera authorization timed out. Click Read to try again.")
    }

    func exchange(_ data: Data) throws -> EngineResponse {
        var size = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(data)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        let header = try readExactly(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= 32 * 1024 * 1024 else { throw PMCAError(message: "The camera response is too large.") }
        return try JSONDecoder().decode(EngineResponse.self, from: readExactly(Int(length)))
    }

    private func readExactly(_ size: Int) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), size - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        return data
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor) // EOF also lets PMCA clean up after a failed request.
            descriptor = -1
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        process = nil
    }

    private func failure() -> PMCAError {
        PMCAError(message: "The camera session ended or stopped responding. Reconnect the camera and click Read again. Any interrupted write must be checked with a fresh read.")
    }
}
