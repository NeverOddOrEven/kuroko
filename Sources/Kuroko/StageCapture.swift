import CoreImage
import CoreMedia
import KurokoCore
import ScreenCaptureKit

extension SCRunningApplication: RunningAppDescribing {}

extension Error {
    func isStreamError(_ code: SCStreamError.Code) -> Bool {
        let error = self as NSError
        return error.domain == SCStreamErrorDomain && error.code == code.rawValue
    }
}

/// Captures the source display minus excluded apps and hands each frame's IOSurface to `onFrame`.
@MainActor
final class StageCapture: NSObject {
    var onFrame: (IOSurfaceRef) -> Void = { _ in }
    var onStop: (Error) -> Void = { _ in }

    /// Everything that exists only while a stream does.
    private struct Session {
        let stream: SCStream
        let output: FrameOutput
        let displayID: CGDirectDisplayID
        var spec: DisplayModeSpec
        var frameRate: Int
        var excludedPIDs: Set<pid_t>
        /// The policy the current filter was built from.
        var policy: ExclusionPolicy
        var isPaused = false
    }

    private var session: Session?
    private let sampleQueue = DispatchQueue(label: "com.neveroddoreven.kuroko.frames", qos: .userInteractive)
    private var lastSurface: IOSurfaceRef?
    /// Bumped by every start and stop, so a start that was overtaken while suspended can tell.
    private var generation = 0

    var isRunning: Bool { session != nil }

    func start(sourceDisplayID: CGDirectDisplayID, spec: DisplayModeSpec, frameRate: Int, policy: ExclusionPolicy) async throws {
        await stop()
        generation += 1
        let token = generation
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard token == generation else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == sourceDisplayID }) else {
            throw KurokoError.capture("source display \(sourceDisplayID) not shareable")
        }
        let excluded = content.applications.filter(policy.isExcluded)
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let output = FrameOutput { [weak self] surface in
            MainActor.assumeIsolated { self?.deliver(surface.surface, generation: token) }
        }
        let configuration = Self.configuration(for: spec, frameRate: frameRate, displayID: sourceDisplayID)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        // A newer start or a stop ran while this one was starting; don't leave this stream running.
        guard token == generation else {
            try? await stream.stopCapture()
            throw CancellationError()
        }

        session = Session(
            stream: stream,
            output: output,
            displayID: sourceDisplayID,
            spec: spec,
            frameRate: frameRate,
            excludedPIDs: Set(excluded.map(\.processID)),
            policy: policy
        )
        log.info("Capture started on display \(sourceDisplayID, privacy: .public), \(excluded.count, privacy: .public) apps excluded")
    }

    /// Re-snapshots running apps and swaps the filter if the excluded set changed.
    func refreshFilter(policy: ExclusionPolicy) async throws {
        guard let session else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == session.displayID }) else { return }
            let excluded = content.applications.filter(policy.isExcluded)
            let pids = Set(excluded.map(\.processID))
            if pids != session.excludedPIDs {
                try await session.stream.updateContentFilter(SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: []))
                log.info("Filter refreshed, \(excluded.count, privacy: .public) apps excluded")
            }
            guard self.session?.stream === session.stream else { return }
            self.session?.excludedPIDs = pids
            // Record the policy even when the filter didn't change: the same excluded apps
            // means the filter already complies with it.
            self.session?.policy = policy
        } catch where self.session?.stream !== session.stream {
            // The stream was replaced or stopped meanwhile; its successor builds its own filter.
        }
    }

    func excludes(_ pid: pid_t) -> Bool {
        session?.excludedPIDs.contains(pid) ?? false
    }

    /// Whether the running filter may still show an app that `policy` excludes.
    func mayShowApps(excludedBy policy: ExclusionPolicy) -> Bool {
        session.map { policy.excludesMore(than: $0.policy) } ?? false
    }

    func updateConfiguration(spec: DisplayModeSpec) async throws {
        guard let session else { return }
        try await reconfigure(session, spec: spec, frameRate: session.frameRate)
    }

    func setFrameRate(_ frameRate: Int) async throws {
        guard let session else { return }
        try await reconfigure(session, spec: session.spec, frameRate: frameRate)
    }

    /// Stops capturing but keeps the stream so `resume()` can restart it.
    func pause() async {
        guard let session, !session.isPaused else { return }
        self.session?.isPaused = true
        try? await session.stream.stopCapture()
    }

    func resume() async throws {
        guard let session, session.isPaused else { return }
        try await session.stream.startCapture()
        if self.session?.stream === session.stream { self.session?.isPaused = false }
    }

    func stop() async {
        generation += 1
        guard let session else { return }
        self.session = nil
        try? await session.stream.stopCapture()
    }

    /// A copy of the last frame that stays valid after the stream stops recycling its surfaces.
    func snapshotLastFrame() -> CGImage? {
        guard let lastSurface else { return nil }
        let image = CIImage(ioSurface: lastSurface)
        return CIContext().createCGImage(image, from: image.extent)
    }

    private func reconfigure(_ session: Session, spec: DisplayModeSpec, frameRate: Int) async throws {
        let configuration = Self.configuration(for: spec, frameRate: frameRate, displayID: session.displayID)
        try await session.stream.updateConfiguration(configuration)
        guard self.session?.stream === session.stream else { return }
        self.session?.spec = spec
        self.session?.frameRate = frameRate
    }

    private func deliver(_ surface: IOSurfaceRef, generation: Int) {
        guard session?.isPaused != true, generation == self.generation else { return }
        lastSurface = surface
        onFrame(surface)
    }

    private static func configuration(for spec: DisplayModeSpec, frameRate: Int, displayID: CGDirectDisplayID) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = spec.pixelWidth
        config.height = spec.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        if let name = CGDisplayCopyColorSpace(displayID).name {
            config.colorSpaceName = name
        }
        return config
    }
}

extension StageCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        log.error("Stream stopped: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public): \(nsError.localizedDescription, privacy: .public)")
        // Delegate callbacks arrive on an arbitrary queue.
        let stopped = ObjectIdentifier(stream)
        let domain = nsError.domain, code = nsError.code, message = nsError.localizedDescription
        Task { @MainActor in
            guard let current = self.session?.stream, ObjectIdentifier(current) == stopped else { return }
            self.session = nil
            onStop(NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
}

/// IOSurfaces are thread-safe; this just lets them cross to the main actor.
private struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurfaceRef
}

private final class FrameOutput: NSObject, SCStreamOutput {
    private let handler: @Sendable (SurfaceBox) -> Void

    init(handler: @escaping @Sendable (SurfaceBox) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        let box = SurfaceBox(surface: surface)
        let handler = handler
        DispatchQueue.main.async { handler(box) }
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
