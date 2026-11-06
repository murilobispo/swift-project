import Foundation
import SwiftCrossUI
import GtkBackend
import ImageFormats

#if canImport(Glibc)
    import Glibc
#endif

#if canImport(Observation)
    import Observation
#endif

@main
struct CameraApp: App {
    @State var feed = CameraFeed()

    var body: some Scene {
        WindowGroup("Camera") {
            VStack {
                if let frame = feed.frame {
                    Image(frame).resizable()
                } else if let status = feed.status {
                    Text(status)
                } else {
                    Text(feed.running ? "Starting camera..." : "Camera not opened yet")
                }

                if feed.running {
                    Button("Stop camera") {
                        feed.stop()
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

/// Runs a GStreamer pipeline that continuously outputs raw RGBA frames from
/// the webcam on stdout. Frames are read on a background task (an explicitly
/// `nonisolated` function, so the main actor is never blocked) and delivered
/// back to the main actor, where updating ``frame`` re-renders the UI
/// automatically.
///
/// `@unchecked Sendable` is sound here: all mutable state is isolated to the
/// main actor (enforced by `@MainActor`), so sending the reference across
/// threads can't race; the background reader only uses it to hop back.
@MainActor
@Observable
final class CameraFeed: @unchecked Sendable {
    var frame: ImageFormats.Image<RGBA>? = nil
    var running = false
    var status: String? = nil

    @ObservationIgnored private var process: Process? = nil
    @ObservationIgnored private var readTask: Task<Void, Never>? = nil

    func start() {
        guard !running else { return }

        let width = 640
        let height = 480

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gst-launch-1.0")
        process.arguments = [
            "-q",
            "v4l2src", "device=/dev/video0",
            "!", "video/x-raw,width=\(width),height=\(height)",
            "!", "videoconvert",
            "!", "video/x-raw,format=RGBA",
            "!", "fdsink", "fd=1",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            status = "Failed to launch GStreamer: \(error.localizedDescription)"
            return
        }

        running = true
        status = nil
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
                width: width,
                height: height,
                deliver: deliver,
                streamEnded: streamEnded
            )
        }
    }

    func stop() {
        guard running else { return }
        running = false
        status = nil
        readTask?.cancel()
        readTask = nil

        if let process {
            // Terminating the pipeline closes the pipe, which makes the
            // background reader see end-of-stream and finish on its own.
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
    }

    /// Called (on the main actor) when the frame stream ends. A user-initiated
    /// ``stop()`` has already flipped ``running`` by then, so this only
    /// reports *unexpected* stream ends.
    private func streamDidEnd() {
        if running {
            running = false
            status = "Camera stream ended unexpectedly. See terminal for details."
        }
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
    }
}
