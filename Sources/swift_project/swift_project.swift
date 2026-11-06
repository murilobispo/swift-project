import Foundation
import SwiftCrossUI
import GtkBackend
import ImageFormats

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

#if canImport(Observation)
    import Observation
#endif

@main
struct CameraApp: App {
    @State var feed = CameraFeed()

    var body: some Scene {
        WindowGroup(feed.windowTitle) {
            VStack {
                // Content area.
                if feed.state == .streaming {
                    if let frame = feed.frame {
                        Image(frame).resizable().aspectRatio(contentMode: .fit)
                    } else if let status = feed.status {
                        Text(status)
                    } else {
                        Text("Starting camera...")
                    }
                } else if feed.state == .captured {
                    if let photo = feed.photo {
                        Image(photo).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Text("No picture taken")
                    }
                } else if let status = feed.status {
                    Text(status)
                } else {
                    Text("Camera not opened yet")
                }

                // Controls.
                if feed.state == .streaming {
                    HStack {
                        Button("Take picture") {
                            feed.capturePhoto()
                        }
                        Button("Stop camera") {
                            feed.stop()
                        }
                    }
                } else {
                    Button("Open camera") {
                        feed.start()
                    }
                }
            }
            .padding()
        }
        .defaultSize(width: 700, height: 560)
    }
}

/// A camera feed backed by GStreamer, using `autovideosrc` so the same
/// pipeline works on Linux, macOS, and Windows without platform-specific
/// camera code.
///
/// Opening the camera happens in two steps:
/// 1. **Probe** — a short-lived pipeline prints the resolution the camera
///    negotiates natively, which we parse from its verbose output.
/// 2. **Stream** — the real pipeline runs with that resolution pinned, and
///    a background task reads fixed-size RGBA frames from its stdout.
///
/// The taken picture is held in memory only (`photo`); nothing is written
/// to disk.
///
/// `@unchecked Sendable` is sound here: all mutable state is isolated to
/// the main actor (enforced by `@MainActor`), so sending the reference
/// across threads can't race; the background reader only uses it to hop
/// back.
@MainActor
@Observable
final class CameraFeed: @unchecked Sendable {
    enum State {
        case idle
        case streaming
        case captured
    }

    var state: State = .idle
    var frame: ImageFormats.Image<RGBA>? = nil
    var photo: ImageFormats.Image<RGBA>? = nil
    var width = 0
    var height = 0
    var status: String? = nil

    var windowTitle: String {
        if state == .streaming, width > 0, height > 0 {
            "Camera — \(width)×\(height)"
        } else {
            "Camera"
        }
    }

    @ObservationIgnored private var process: Process? = nil
    @ObservationIgnored private var readTask: Task<Void, Never>? = nil

    func start() {
        guard state != .streaming else { return }

        state = .streaming
        status = nil
        photo = nil
        frame = nil

        guard let gstLaunch = Self.locateGstLaunch() else {
            state = .idle
            status = "gst-launch-1.0 not found. Please install GStreamer."
            return
        }

        // Discover the camera's native resolution (opens and closes the
        // camera once; takes roughly a second).
        guard let resolution = Self.probeResolution(gstLaunch: gstLaunch) else {
            state = .idle
            status = "Couldn't detect the camera resolution. Is a camera connected?"
            return
        }

        width = resolution.width
        height = resolution.height

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gstLaunch)
        process.arguments = [
            "-q",
            "autovideosrc",
            "!", "videoconvert",
            "!", "video/x-raw,format=RGBA,width=\(resolution.width),height=\(resolution.height)",
            "!", "fdsink", "fd=1",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            state = .idle
            status = "Failed to launch the camera pipeline: \(error.localizedDescription)"
            return
        }

        self.process = process

        // The background reader never touches `self`; it delivers finished
        // frames (and stream-end events) back to the main actor through these
        // closures, created here on the main actor where capturing self is
        // safe.
        let fd = pipe.fileHandleForReading.fileDescriptor
        let deliver: @Sendable @MainActor (ImageFormats.Image<RGBA>) -> Void = { [weak self] image in
            self?.frame = image
        }
        let streamEnded: @Sendable @MainActor () -> Void = { [weak self] in
            self?.streamDidEnd()
        }

        // IMPORTANT: `Task.detached` (not a regular `Task`) is required here.
        // A regular Task inherits the main actor, and nonisolated async
        // functions run on their *caller's* executor — so the blocking
        // reads would end up on the main actor and freeze the UI. A detached
        // task runs on the global concurrent executor, keeping the main
        // thread free for the UI.
        readTask = Task.detached {
            await Self.readFrames(
                fd: fd,
                width: resolution.width,
                height: resolution.height,
                deliver: deliver,
                streamEnded: streamEnded
            )
        }
    }

    /// Captures the current frame as the photo and turns the camera off.
    /// The picture is kept in memory only.
    func capturePhoto() {
        guard state == .streaming, let currentFrame = frame else { return }
        photo = currentFrame
        stopCamera()
        state = .captured
    }

    func stop() {
        guard state == .streaming else { return }
        stopCamera()
        state = .idle
    }

    private func stopCamera() {
        readTask?.cancel()
        readTask = nil

        if let process {
            // Terminating the pipeline closes the pipe, which makes the
            // background reader see end-of-stream and finish on its own.
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        frame = nil
    }

    /// Called (on the main actor) when the frame stream ends. A user-initiated
    /// stop or capture has already changed ``state`` by then, so this only
    /// reports *unexpected* stream ends.
    private func streamDidEnd() {
        if state == .streaming {
            state = .idle
            status = "Camera stream ended unexpectedly. See terminal for details."
        }
    }

    /// Locates the `gst-launch-1.0` executable: PATH first (so custom
    /// installs win), then well-known install locations. Missing candidates
    /// simply fail the check, which keeps this list valid on every platform.
    private static func locateGstLaunch() -> String? {
        let fileManager = FileManager.default

        var candidates: [String] = []
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            candidates.append("\(directory)/gst-launch-1.0")
        }

        candidates += [
            "/usr/bin/gst-launch-1.0",
            "/usr/local/bin/gst-launch-1.0",
            "/opt/homebrew/bin/gst-launch-1.0",
            "C:\\gstreamer\\1.0\\msvc_x86_64\\bin\\gst-launch-1.0.exe",
            "C:\\gstreamer\\1.0\\mingw_x86_64\\bin\\gst-launch-1.0.exe",
        ]

        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Runs a short-lived pipeline and parses the resolution the camera
    /// negotiates natively from its verbose output. Blocks for up to a few
    /// seconds (bounded by a deadline) while the camera starts up.
    private static func probeResolution(gstLaunch: String) -> (width: Int, height: Int)? {
        #if canImport(Glibc) || canImport(Darwin)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gstLaunch)
            process.arguments = [
                "-v",
                "autovideosrc",
                "!", "videoconvert",
                "!", "video/x-raw,format=RGBA",
                "!", "fakesink",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe

            do {
                try process.run()
            } catch {
                return nil
            }

            defer {
                if process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
            }

            let fd = pipe.fileHandleForReading.fileDescriptor

            // Non-blocking reads with a deadline, so a hung pipeline can't
            // freeze the app forever.
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            }

            let deadline = Date().addingTimeInterval(4)
            var output = [UInt8]()

            while Date() < deadline {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let bytesRead = read(fd, &chunk, chunk.count)

                if bytesRead > 0 {
                    output.append(contentsOf: chunk[0..<bytesRead])
                    if
                        let text = String(bytes: output, encoding: .utf8),
                        let width = intAfter("width=(int)", in: text),
                        let height = intAfter("height=(int)", in: text)
                    {
                        return (width, height)
                    }
                } else if bytesRead == 0 {
                    break  // End of output: the process ended before negotiating.
                } else {
                    // EAGAIN: nothing available yet. Anything else is an error.
                    if errno != EAGAIN { break }
                    usleep(20_000)  // 20 ms.
                }

                if !process.isRunning { break }
            }

            return nil
        #else
            // Windows would need WinAPI-based pipe IO; not implemented yet.
            return nil
        #endif
    }

    /// Reads the integer immediately after `marker` in `text`, e.g.
    /// `width=(int)1280`.
    private static func intAfter(_ marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// Reads fixed-size raw RGBA frames from a file descriptor. Explicitly
    /// `nonisolated` so the blocking `read()` calls run on the global
    /// concurrent executor instead of ever blocking the main actor.
    nonisolated private static func readFrames(
        fd: Int32,
        width: Int,
        height: Int,
        deliver: @Sendable @MainActor (ImageFormats.Image<RGBA>) -> Void,
        streamEnded: @Sendable @MainActor () -> Void
    ) async {
        #if canImport(Glibc) || canImport(Darwin)
            let frameSize = width * height * 4

            frameLoop: while true {
                if Task.isCancelled { break frameLoop }

                var buffer = [UInt8](repeating: 0, count: frameSize)
                var offset = 0

                // Read exactly one frame (read() may return partial data).
                while offset < frameSize {
                    let bytesRead = read(fd, &buffer[offset], frameSize - offset)
                    if bytesRead == 0 { break frameLoop }  // End of stream
                    if bytesRead < 0 {
                        if errno == EINTR { continue }
                        break frameLoop  // Read error
                    }
                    offset += bytesRead
                }

                let image = ImageFormats.Image<RGBA>(width: width, height: height, bytes: buffer)
                await deliver(image)
            }

            await streamEnded()
        #else
            // Windows would need WinAPI-based pipe IO; not implemented yet.
            await streamEnded()
        #endif
    }
}
