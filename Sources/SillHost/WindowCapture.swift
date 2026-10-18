import Foundation
import ScreenCaptureKit
import CoreMedia

/// Runs one ScreenCaptureKit stream (a window or a display) and hands out 420f pixel buffers.
/// The coordinator stops and restarts it whenever the client picks a different source.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Why `start` can refuse: a stream that did not stop would otherwise be overwritten, and its
    /// frames would reach the new encoder at the old size (the header's macOS 27 wedge).
    enum Failure: LocalizedError {
        case streamStillRunning
        var errorDescription: String? {
            switch self {
            case .streamStillRunning:
                return "the previous capture stream is still registered: it did not stop"
            }
        }
    }

    /// How long a started stream may go without a first frame before the coordinator says so. A
    /// stream that starts and never delivers is otherwise silent forever: no stop error, no frame,
    /// every counter zero, and the device shows black with nothing to explain it.
    static let firstFrameTimeout = 1.5

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "sill.capture", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// The stream ended on its own (window closed, permission revoked). Called on an SCK thread.
    var onStopped: ((Error) -> Void)?

    /// `showsCursor`: draw the Mac cursor into the frames. The host passes false: the client draws
    /// the pointer itself (with the Mac's current shape, sent separately), so the video never
    /// carries a round-trip-late cursor. Never change this on a running stream:
    /// `SCStream.updateConfiguration` wedged the stream on macOS 27 (frames stopped, the next
    /// `stopCapture` never returned, and the coordinator's switch flag stayed set for good).
    ///
    /// `sourceRect`: `--virtual-display` only. The part of a display filter to encode, in points in
    /// the display's own coordinate system (origin at its top-left, SCStream.h), i.e. exactly the
    /// staged window's rectangle, so the device gets the window and nothing else. Nil (the default,
    /// and the whole default path) leaves the configuration exactly as it was.
    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool, sourceRect: CGRect? = nil) async throws {
        if let stream {
            // Never two streams on this queue: the old one's frames would be handed to the encoder
            // the coordinator has already pointed `onFrame` at, at the wrong size, and the old
            // encoder would be pinned by that closure (its deinit is the only VT invalidation).
            print("Capture: start refused, a stream is still registered (\(stream))")
            Stats.shared.bump("cap.startWhileRunning")
            throw Failure.streamStillRunning
        }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5   // headroom: a wedged encoder may keep one buffer forever
        config.showsCursor = showsCursor
        config.colorSpaceName = CGColorSpace.sRGB
        if let sourceRect {
            config.sourceRect = sourceRect
            config.ignoreShadowsDisplay = true                 // the crop is the window's frame; its shadow would be clipped anyway
            config.backgroundColor = Self.black                  // deterministic black behind the rounded corners
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        // Register before starting: a stop error that arrives during start must not be swallowed
        // by the identity check in didStopWithError.
        self.stream = stream
        // `framesSeen` belongs to `queue`, which the sample callback runs on: reset it there rather
        // than on the thread calling start (an unsynchronised `var` written from two threads is a
        // data race, however unlikely the overlap).
        queue.sync { framesSeen = 0 }
        do {
            try await stream.startCapture()
        } catch {
            if self.stream === stream { self.stream = nil }
            throw error
        }
        let crop = sourceRect.map { String(format: " sourceRect (%.0f,%.0f,%.0f,%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? ""
        print("Capture started: \(width)×\(height) @\(fps) fps, cursor \(showsCursor ? "in" : "out"), filter \(filter.contentRect.size) scale \(filter.pointPixelScale)" + crop)
    }

    private var framesSeen = 0   // on `queue`
    /// Frames delivered since `start`, read through the queue so the coordinator's first-frame
    /// check cannot race the sample callback.
    var framesDelivered: Int { queue.sync { framesSeen } }
    /// Held by the type: `SCStreamConfiguration.backgroundColor` is unowned(unsafe) and would not keep
    /// a temporary alive.
    private static let black = CGColor(gray: 0, alpha: 1)

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
            self.stream = nil
        } catch {
            // The handle stays: a stream that refused to stop keeps delivering to this capture queue,
            // and dropping the reference would make it both unretryable and invisible (start() then
            // refuses rather than building a second one over it). This is the wedge the header
            // describes, so it gets a line rather than a `try?`.
            print("Capture: stopCapture failed (\(error)); the stream is still registered")
            Stats.shared.bump("cap.stopFailed")
        }
        // stopCapture returning does not mean the sample-handler queue has drained. Wait for it,
        // so no late frame reaches the next encoder at the old size.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else { Stats.shared.bump("cap.noStatus"); return }
        // .idle frames (nothing changed) are skipped, which is what we want.
        guard status == .complete else { Stats.shared.bump(status == .idle ? "cap.idle" : "cap.status\(statusRaw)"); return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { Stats.shared.bump("cap.noPixels"); return }
        Stats.shared.bump("cap.complete")
        framesSeen += 1
        if framesSeen == 1 { print("Capture: first frame \(CVPixelBufferGetWidth(pixelBuffer))×\(CVPixelBufferGetHeight(pixelBuffer))") }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let current = stream === self.stream
        print("Capture stream stopped (\(current ? "current" : "replaced")): \(error) — \((error as NSError).userInfo)")
        guard current else { return }   // a stream we already replaced
        self.stream = nil
        onStopped?(error)
    }
}

/// HEVC wants even dimensions.
func evenPixels(_ v: CGFloat) -> Int { Int(v.rounded(.down)) & ~1 }
