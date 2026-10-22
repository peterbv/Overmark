import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PresentifyCapture
import PresentifyCore
import ScreenCaptureKit

/// The video half of the presentation recorder when the target is a single
/// window: a `SCStream` filtered to one `SCWindow`, feeding the pipeline.
///
/// A single-window capture never includes the annotation canvases — they live
/// in separate overlay windows — so every delivered frame is redrawn with the
/// current annotations before it reaches the writer: the recording shows the
/// drawing even though the tape only follows the chosen window. The burn-in
/// happens here, on the stream callback queue, using the same coordinate
/// mapping the screenshot compositing does (`global point → target pixels`).
///
/// The video track is sized once from the window at start. If the window is
/// resized mid-session the stream letterboxes the content into the fixed
/// track (`preservesAspectRatio`), which keeps the file coherent the whole
/// run — reconfiguring a writer mid-recording is not possible.
final class WindowRecordingSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// A window found on screen, with all the geometry the run needs.
    struct ResolvedWindow {
        /// The ScreenCaptureKit window the stream will subscribe to.
        let window: SCWindow
        /// The window's frame in AppKit screen coordinates (bottom-left
        /// origin, points) — the space annotations live in.
        let appKitFrame: CGRect
        /// The encode resolution in pixels (even, capped by the orchestrator).
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// The pipeline whose queue the stream frames onto — the same serial
    /// queue appends and the burn-in draw run on, so frames never change
    /// threads.
    private let pipeline: RecorderPipeline
    /// The annotation set to burn in, read fresh for every frame (drawings
    /// continue while the recording runs). The app layer owns the store;
    /// reading it here costs a lock, not a copy of the document.
    private let annotationsProvider: @Sendable () -> [Annotation]
    /// The window frame the current frames were generated against, in the
    /// annotation space (AppKit screen coordinates, points).
    private var windowFrame: CGRect

    init(
        pipeline: RecorderPipeline,
        annotationsProvider: @escaping @Sendable () -> [Annotation],
        windowFrame: CGRect
    ) {
        self.pipeline = pipeline
        self.annotationsProvider = annotationsProvider
        self.windowFrame = windowFrame
        super.init()
    }

    /// Finds the chosen window among what is on screen right now and sizes
    /// the run around it.
    ///
    /// - Parameters:
    ///   - choice: The title + owner pairing that was saved with the
    ///     settings; it is a policy, resolved here against live windows.
    ///   - cappedPixels: The largest encode resolution, so a huge window does
    ///     not ask the encoder for a size it refuses.
    static func resolve(
        _ choice: RecordingWindowChoice,
        cappedPixels: Int
    ) async throws -> ResolvedWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let windows = content.windows.filter {
            !($0.title ?? "").isEmpty
        }
        // The owner is preferred so two apps showing the same title do not
        // clash; a title-only match keeps recordings working in front of a
        // relabeled app.
        let ownerMatch = windows.first {
            $0.title == choice.title && $0.owningApplication?.applicationName == choice.ownerName
        }
        let matched = ownerMatch ?? windows.first {
            $0.title == choice.title
        }

        guard let window = matched else {
            throw RecorderDisplayError.windowGone
        }

        let appFrame = appKitFrame(ofWindowFrame: window.frame)
        let scale = backingScale(forScreenContaining: appFrame)
        let pixels = fittedPixelSize(
            widthPoints: appFrame.width,
            heightPoints: appFrame.height,
            scale: scale,
            cappedPixels: cappedPixels
        )
        return ResolvedWindow(
            window: window,
            appKitFrame: appFrame,
            pixelWidth: pixels.width,
            pixelHeight: pixels.height
        )
    }

    /// Starts the stream over the resolved window.
    ///
    /// - Parameters:
    ///   - resolved: The window + geometry from `resolve(_:cappedPixels:)`.
    ///   - frameRate: Target capture rate.
    func start(_ resolved: ResolvedWindow, frameRate: Int) async throws {
        guard !isRunning else { return }

        let configuration = SCStreamConfiguration()
        configuration.width = resolved.pixelWidth
        configuration.height = resolved.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 8
        // The saver keeps the aspect if the window is resized so nothing
        // stretches; the desktop-independent filter frames the window
        // content itself, without the app's shadow.
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: resolved.window),
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
        self.windowFrame = resolved.appKitFrame
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

    // MARK: - Geometry helpers

    /// Converts an `SCWindow.frame` — top-left global origin, points — into
    /// the AppKit screen coordinates the annotations use (bottom-left
    /// global origin, points).
    static func appKitFrame(ofWindowFrame windowFrame: CGRect) -> CGRect {
        // The AppKit global origin sits at the bottom-left of the primary
        // screen; ScreenCaptureKit (like `CGWindow` lists) counts from the
        // top-left, so the vertical axis mirrors around the primary height.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? windowFrame.maxY
        let origin = CGPoint(
            x: windowFrame.origin.x,
            y: primaryTop - windowFrame.maxY
        )
        return CGRect(origin: origin, size: windowFrame.size)
    }

    /// The backing scale of the screen the window sits on.
    private static func backingScale(forScreenContaining frame: CGRect) -> Double {
        let screen = NSScreen.screens.first { screen in
            NSPointInRect(
                CGPoint(
                    x: frame.midX,
                    y: frame.midY
                ),
                screen.frame
            )
        }
        return Double(screen?.backingScaleFactor ?? 1)
    }

    /// Pixel size for the encode: points × scale, capped on the long edge
    /// and forced to even values — the H.264 engine rejects odd dimensions.
    static func fittedPixelSize(
        widthPoints: CGFloat,
        heightPoints: CGFloat,
        scale: Double,
        cappedPixels: Int
    ) -> (width: Int, height: Int) {
        var width = Int((Double(widthPoints) * scale).rounded())
        var height = Int((Double(heightPoints) * scale).rounded())

        let largest = max(width, height)
        if largest > cappedPixels {
            let factor = Double(cappedPixels) / Double(largest)
            width = Int((Double(width) * factor).rounded())
            height = Int((Double(height) * factor).rounded())
        }

        // H.264 wants even sizes; stepping down by a pixel is invisible.
        if width % 2 != 0 { width = max(2, width - 1) }
        if height % 2 != 0 { height = max(2, height - 1) }
        return (width, height)
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
        drawAnnotations(onto: pixelBuffer)
        pipeline.appendScreenFrame(
            pixelBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    func streamDidBecomeAvailable(_ stream: SCStream) {}
    func streamWillStop(_ stream: SCStream) {}
    func streamDidStop(_ stream: SCStream) {}

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The window closed or the stream broke; the run still produces
        // whatever was written up to this point.
        pipeline.note(streamFailure: error)
    }

    // MARK: - Annotation burn-in

    /// Draws the current annotations straight into the frame's pixel memory.
    ///
    /// The frames the encoder expects are top-down, while a `CGContext` over
    /// the same memory is bottom-up, so the mapping folds into one matrix:
    /// for a global point `p`, the pixel is
    /// `((p.x − frame.minX)·scale, (frame.maxY − p.y)·scale)` — the same
    /// point-per-pixel geometry the screenshot compositing applies, minus
    /// the round trip through an image.
    private func drawAnnotations(onto pixelBuffer: CVPixelBuffer) {
        let annotations = annotationsProvider()
        guard !annotations.isEmpty else { return }
        guard windowFrame.width > 0, windowFrame.height > 0 else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // `32BGRA` buffers are little-endian `ARGB` to Core Graphics, which
        // reads back as premultiplied-first with a 32-bit little word.
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        let scale = CGFloat(Double(width) / windowFrame.width)
        let windowRect = Rect(
            origin: Point(x: windowFrame.minX, y: windowFrame.minY),
            size: Size(width: windowFrame.width, height: windowFrame.height)
        )
        let relevant = annotations.filter {
            windowRect.contains($0.bounds.center)
        }
        guard !relevant.isEmpty else { return }

        context.concatenate(
            CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: -scale,
                tx: -scale * windowFrame.minX,
                ty: scale * windowFrame.maxY
            )
        )

        let renderer = AnnotationRenderer(style: .init(scale: 1))
        for annotation in relevant {
            renderer.draw(annotation, in: context)
        }
    }

    private var stream: SCStream?
    private var isRunning = false
}
