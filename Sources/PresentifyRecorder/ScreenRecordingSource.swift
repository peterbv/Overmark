import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// The video half of the presentation recorder: a `SCStream` over one
/// display, feeding screen frames into the pipeline.
///
/// The stream captures the *whole display* — the annotation canvases, the
/// cursor-effect windows and the system cursor included. Only the app's
/// control chrome (toolbar, cheat-sheet, settings, editor) is excluded, and
/// only because those windows belong to this app: the presenter would see
/// them in the video otherwise. The exclusion works by `NSWindow.windowNumber`
/// so the caller collects them without any ScreenCaptureKit knowledge.
final class ScreenRecordingSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// The pipeline whose queue the stream frames onto — the same serial
    /// queue appends run on, so frames never change threads.
    private let pipeline: RecorderPipeline

    private var stream: SCStream?
    private var isRunning = false

    init(pipeline: RecorderPipeline) {
        self.pipeline = pipeline
    }

    /// Starts a whole-display stream.
    ///
    /// - Parameters:
    ///   - displayID: The `CGDirectDisplayID` to record.
    ///   - pixelWidth/pixelHeight: The encode resolution in pixels, already
    ///     capped by the orchestrator; the stream scales the display to
    ///     exactly these dimensions so its buffers match the writer's track
    ///     size frame for frame.
    ///   - frameRate: Target capture rate.
    ///   - excludedWindowNumbers: App chrome that must not appear in the file.
    func start(
        displayID: CGDirectDisplayID,
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Int,
        excludedWindowNumbers: Set<Int>
    ) async throws {
        guard !isRunning else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecorderDisplayError.displayGone
        }
        // Exclusion is by number so that AppKit-owned chrome is found by
        // NSWindow.windowNumber; SCK exposes its own id under the same value.
        let excludedWindows = content.windows.filter {
            excludedWindowNumbers.contains(Int($0.windowID))
        }

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: excludedWindows),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: SCStreamOutputType.screen,
            sampleHandlerQueue: pipeline.callbackQueue
        )
        try await stream.startCapture()

        self.stream = stream
        isRunning = true
    }

    /// Stops the stream. Frames that are already queued still reach the
    /// pipeline, so the tail of the session is not lost by stopping first.
    func stop() async {
        guard let stream, isRunning else { return }
        isRunning = false
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: SCStreamOutputType.screen)
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        pipeline.appendScreenFrame(
            pixelBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    func streamDidBecomeAvailable(_ stream: SCStream) {}
    func streamWillStop(_ stream: SCStream) {}
    func streamDidStop(_ stream: SCStream) {}

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The display vanished or the stream broke; the run still produces
        // whatever was written up to this point.
        pipeline.note(streamFailure: error)
    }
}

public enum RecorderDisplayError: LocalizedError {
    case displayGone
    case windowGone

    public var errorDescription: String? {
        switch self {
        case .displayGone: "The display to record is no longer available."
        case .windowGone: "The window to record is no longer available."
        }
    }
}
