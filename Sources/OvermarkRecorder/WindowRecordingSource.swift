import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OvermarkCapture
import OvermarkCore
import ScreenCaptureKit

/// The video half of the presentation recorder when the target is a single
/// window: a `SCStream` filtered to one `SCWindow`, feeding the pipeline.
///
/// A single-window capture never includes the annotation canvases — they live
/// in separate overlay windows — so every delivered frame is redrawn with the
/// current annotations before it reaches the writer: the recording shows the
/// drawing even though the tape only follows the chosen window. The burn-in
/// happens here, on the stream callback queue, using the per-frame geometry
/// the stream attaches to each sample (`SCStreamFrameInfo`).
///
/// The video track is sized once from the window at start (an `AVAssetWriter`
/// track cannot change mid-file). Since macOS 14 the stream scales the window
/// *up and down* into that fixed track (`scalesToFit`), so a resized window
/// keeps filling the whole video instead of leaving crop bands, and the
/// annotations follow the window's live geometry read from each frame.
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
    /// The cursor-effect state to burn in, read fresh for every frame.
    /// `nil` results skip the effect pass; the frame still carries burned
    /// annotations when it has any.
    private let effectsProvider: @Sendable () -> CursorEffectFrame?
    /// The window frame the current frames were generated against, in the
    /// annotation space (AppKit screen coordinates, points).
    private var windowFrame: CGRect
    /// Pixel-to-points factor of the stream's output surface, read once at
    /// start (`SCStream.pointPixelScale`, macOS 14+). It is the bridge
    /// between frame-info rects reported in points and the buffer's pixels.
    private var surfaceScale: CGFloat = 1

    init(
        pipeline: RecorderPipeline,
        annotationsProvider: @escaping @Sendable () -> [Annotation],
        effectsProvider: @escaping @Sendable () -> CursorEffectFrame? = { nil },
        windowFrame: CGRect
    ) {
        self.pipeline = pipeline
        self.annotationsProvider = annotationsProvider
        self.effectsProvider = effectsProvider
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
        // The stream scales the window up and down into the track, so a
        // window resized mid-session still fills the whole video instead of
        // cropping (`scalesToFit` is macOS 14+, and the docs call it out for
        // desktop-independent — single-window — filters, which is exactly
        // this stream).
        configuration.scalesToFit = true
        // Content that fits exactly fills the buffer; aspect preservation
        // would add black bars whenever the window's aspect ratio drifts
        // away from the track's. Any stretch the stream applies is measured
        // per frame from the frame info, never assumed.
        configuration.preservesAspectRatio = false
        // The desktop-independent filter frames the window content itself,
        // without the app's shadow.
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(desktopIndependentWindow: resolved.window)
        let stream = SCStream(
            filter: filter,
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
        self.surfaceScale = CGFloat(max(filter.pointPixelScale, 1))
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

    // MARK: - Frame information
    // The stream attaches rects to every sample. `screenRect` is where the
    // captured content sat on screen (the window's *current* frame), and
    // `contentRect` is where it landed inside the delivered buffer. Reading
    // both per frame is what lets the burn-in follow a window that moved or
    // resized while the recording ran — no polling, no reconfiguration.

    /// The per-frame mapping answers: where the content now sits in the
    /// annotation space and which part of the delivered buffer it occupies.
    struct FrameGeometry: Sendable {
        /// The content's current frame in AppKit coordinates (points).
        var contentFrameAppKit: CGRect
        /// The content's rect inside the delivered buffer, in pixels.
        var contentRectInPixels: CGRect
    }

    /// Reads the frame-info rects out of one sample buffer.
    ///
    /// Returns `nil` when the stream did not attach them — the burn-in then
    /// falls back to the frame the run was started with.
    nonisolated func frameGeometry(for sampleBuffer: CMSampleBuffer, bufferSize: CGSize) -> FrameGeometry? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [NSDictionary], let info = attachments.first else {
            return nil
        }
        let screenRect = (info[SCStreamFrameInfo.screenRect] as? NSValue)?.rectValue
        let contentRect = (info[SCStreamFrameInfo.contentRect] as? NSValue)?.rectValue
        guard let screenRect, screenRect.width > 0, screenRect.height > 0 else { return nil }

        let scale = max(surfaceScale, 1)
        return FrameGeometry(
            contentFrameAppKit: Self.contentFrameAppKit(
                rawScreenRect: screenRect,
                knownFrame: windowFrame,
                pointPixelScale: scale
            ),
            contentRectInPixels: Self.contentRectInPixels(
                rawContentRect: contentRect,
                bufferSize: bufferSize,
                pointPixelScale: scale
            )
        )
    }

    /// Converts the stream's `screenRect` into AppKit screen coordinates.
    ///
    /// The stream reports the location in the ScreenCaptureKit convention —
    /// the same top-left global space `SCWindow.frame` uses — but rects can
    /// be expressed in surface points or pixels depending on the capture
    /// scale. Rather than trusting a convention, the first frame is
    /// calibrated against the window frame the run was resolved with
    /// (`knownFrame`): the candidate whose result is closest to it wins, and
    /// the whole mapping is built from that measured answer.
    static func contentFrameAppKit(
        rawScreenRect: CGRect,
        knownFrame: CGRect,
        pointPixelScale: CGFloat
    ) -> CGRect {
        let candidates = [
            rawScreenRect,
            appKitFrame(ofWindowFrame: rawScreenRect),
            appKitFrame(ofWindowFrame: CGRect(
                origin: CGPoint(x: rawScreenRect.origin.x, y: rawScreenRect.origin.y),
                size: CGSize(
                    width: rawScreenRect.width / pointPixelScale,
                    height: rawScreenRect.height / pointPixelScale
                )
            )),
        ]
        var best = candidates[0]
        var bestDistance = rectDistanceInAppKit(candidates[0], knownFrame: knownFrame)
        for candidate in candidates.dropFirst() {
            let distance = rectDistanceInAppKit(candidate, knownFrame: knownFrame)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    /// The normalized L1 distance between a candidate and the window frame
    /// the run started with; scales both axes by the frame size so one
    /// number fits windows of any size.
    static func rectDistanceInAppKit(_ candidate: CGRect, knownFrame: CGRect) -> CGFloat {
        guard knownFrame.width > 0, knownFrame.height > 0 else { return .infinity }
        let dx = abs(candidate.midX - knownFrame.midX) / knownFrame.width
        let dy = abs(candidate.midY - knownFrame.midY) / knownFrame.height
        let dw = abs(candidate.width - knownFrame.width) / knownFrame.width
        let dh = abs(candidate.height - knownFrame.height) / knownFrame.height
        return dx + dy + dw + dh
    }

    /// Converts the stream's `contentRect` (rect of the content "in points
    /// in surface") into buffer pixels, choosing between the raw value and
    /// its scale-scaled variant the one whose extent matches the buffer
    /// more closely.
    static func contentRectInPixels(
        rawContentRect: CGRect?,
        bufferSize: CGSize,
        pointPixelScale: CGFloat
    ) -> CGRect {
        guard let rawContentRect,
              rawContentRect.width > 0,
              rawContentRect.height > 0,
              bufferSize.width > 0,
              bufferSize.height > 0 else {
            // No content rect: the content is assumed to fill the buffer.
            return CGRect(origin: .zero, size: bufferSize)
        }
        let scaled = CGRect(
            x: rawContentRect.origin.x * pointPixelScale,
            y: rawContentRect.origin.y * pointPixelScale,
            width: rawContentRect.width * pointPixelScale,
            height: rawContentRect.height * pointPixelScale
        )
        let rawDistance = abs(rawContentRect.width - bufferSize.width) / bufferSize.width
            + abs(rawContentRect.height - bufferSize.height) / bufferSize.height
        let scaledDistance = abs(scaled.width - bufferSize.width) / bufferSize.width
            + abs(scaled.height - bufferSize.height) / bufferSize.height
        return scaledDistance < rawDistance ? scaled : rawContentRect
    }

    /// The global-annotation-point → buffer-pixel transform for one frame:
    /// the content's AppKit frame (`contentFrame`) mapped into the part of
    /// the buffer it occupies (`contentRect`), vertical axis flipped for
    /// the top-down pixel space. Distinct axis factors let the transform
    /// follow whatever scaling the stream applied to each axis.
    static func annotationTransform(contentFrame: CGRect, contentRect: CGRect) -> CGAffineTransform {
        let scaleX = CGFloat(contentRect.width / contentFrame.width)
        let scaleY = CGFloat(contentRect.height / contentFrame.height)
        return CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: -scaleY,
            tx: CGFloat(contentRect.minX) - scaleX * contentFrame.minX,
            ty: CGFloat(contentRect.minY) + scaleY * contentFrame.maxY
        )
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
        let geometry = frameGeometry(
            for: sampleBuffer,
            bufferSize: CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        )
        let prepared = preparedFrame(onto: pixelBuffer, geometry: geometry)
        pipeline.appendScreenFrame(
            prepared,
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

    // MARK: - Content burn-in

    /// Returns the frame to hand to the encoder: `buffer` untouched when
    /// nothing needs burning in (the common frame — zero copies), or a
    /// private copy with the annotations and cursor effects baked in.
    ///
    /// Whatever gets drawn is drawn into a copy, never into the delivered
    /// buffer itself: the buffer belongs to SCStream, which recycles it
    /// from its own pool, so under writer backpressure a frame can be
    /// reused or read while we draw — tearing the burn-in or bleeding
    /// pixels between frames. Drawing into memory we own removes that
    /// shared state. When the copy cannot be made, the burn-in falls back
    /// to drawing in place, favouring the feature over the old sharing
    /// risk.
    ///
    /// The frames the encoder expects are top-down, while a `CGContext` over
    /// the same memory is bottom-up, so the mapping folds into one matrix:
    /// for a global point `p`, the pixel is
    /// `((p.x − frame.minX)·sx + content.minX, (frame.topY − p.y)·sy + content.topY)`
    /// where `frame` is the window's *current* frame (per frame info when
    /// the stream provides it, the resolved frame otherwise) and `content`
    /// is the part of the buffer the content occupies. Resizes therefore
    /// morph the burned-in annotations with the window instead of fixing
    /// them to the geometry at start.
    ///
    /// Cursor effects are painted with the same matrix, in AppKit screen
    /// space, so they land where they float on the screen. The lens burns a
    /// *clean* snapshot taken before annotations land, mirroring the
    /// on-screen lens which excludes the overlay windows from its capture.
    private func preparedFrame(onto buffer: CVPixelBuffer, geometry: FrameGeometry?) -> CVPixelBuffer {
        let annotations = annotationsProvider()
        let effectFrame = effectsProvider().flatMap {
            $0.hasBurnableContent ? $0 : nil
        }
        guard !annotations.isEmpty || effectFrame != nil else { return buffer }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return buffer }

        // Which AppKit rect the current frame shows and where it sits in
        // the buffer: the measured geometry when present, the resolved
        // window frame and a full-buffer content otherwise.
        let contentFrame = geometry?.contentFrameAppKit ?? windowFrame
        var content = geometry?.contentRectInPixels
            ?? CGRect(x: 0, y: 0, width: width, height: height)
        // The buffer holds whole pixels; a fraction of a pixel from a
        // floating-point content rect is clamped so the matrix stays sane.
        content = content.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard content.width > 0, content.height > 0 else { return buffer }
        guard contentFrame.width > 0, contentFrame.height > 0 else { return buffer }

        let target = Self.makeCopy(of: buffer) ?? buffer
        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(target) else { return buffer }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // `32BGRA` buffers are little-endian `ARGB` to Core Graphics, which
        // reads back as premultiplied-first with a 32-bit little word.
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(target),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return target }

        // The window content alone, before anything is burned in: the zoom
        // lens magnifies un-annotated pixels, like it does on-screen.
        let cleanSnapshot: CGImage? = effectFrame?.effects.isZoomEnabled == true
            ? context.makeImage()
            : nil

        let windowRect = Rect(
            origin: Point(x: contentFrame.minX, y: contentFrame.minY),
            size: Size(width: contentFrame.width, height: contentFrame.height)
        )
        let transform = Self.annotationTransform(contentFrame: contentFrame, contentRect: content)

        // Annotations first: they belong to the content, effects float on
        // top of them, exactly like the composed screen does on the canvas.
        let relevant = annotations.filter {
            windowRect.contains($0.bounds.center)
        }
        if !relevant.isEmpty {
            context.saveGState()
            context.concatenate(transform)
            let renderer = AnnotationRenderer(style: .init(scale: 1))
            for annotation in relevant {
                renderer.draw(annotation, in: context)
            }
            context.restoreGState()
        }

        guard let effectFrame else { return target }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(transform)

        // Effects paint in AppKit screen space (window coordinates resolve
        // through the same matrix annotation spots do). The pointer effects
        // follow the pointer, which lives on exactly one display — like the
        // on-screen windows, only the display hosting the cursor punches a
        // hole, magnifies or rings.
        let cursorCGPoint = effectFrame.cursor.map { CGPoint(x: $0.x, y: $0.y) }
        let windowCGRect = CGRect(
            x: contentFrame.minX,
            y: contentFrame.minY,
            width: contentFrame.width,
            height: contentFrame.height
        )
        let isCursorHere = cursorCGPoint.map { windowCGRect.contains($0) } ?? false

        if effectFrame.effects.isSpotlightEnabled {
            CursorEffectRenderer.drawSpotlight(
                dimRect: CGRect(
                    x: contentFrame.minX,
                    y: contentFrame.minY,
                    width: contentFrame.width,
                    height: contentFrame.height
                ),
                holeCenter: isCursorHere ? cursorCGPoint : nil,
                holeRadius: effectFrame.effects.spotlightRadius,
                dimOpacity: effectFrame.effects.spotlightDimOpacity,
                in: context
            )
        }

        if effectFrame.effects.isZoomEnabled, isCursorHere, let cursor = cursorCGPoint, let clean = cleanSnapshot {
            CursorEffectRenderer.drawZoomLens(
                at: cursor,
                around: CGPoint(
                    x: cursor.x - contentFrame.minX,
                    y: cursor.y - contentFrame.minY
                ),
                size: effectFrame.effects.zoomSize,
                zoomFactor: effectFrame.effects.zoomFactor,
                shape: effectFrame.effects.zoomShape,
                background: clean,
                contentOriginInPixels: CGPoint(
                    x: content.minX,
                    y: content.minY
                ),
                pixelsPerPointX: content.width / contentFrame.width,
                pixelsPerPointY: content.height / contentFrame.height,
                pointHeight: contentFrame.height,
                in: context
            )
        }

        if effectFrame.effects.isHighlightEnabled, isCursorHere, let cursor = cursorCGPoint {
            CursorEffectRenderer.drawHighlight(
                center: cursor,
                radius: effectFrame.effects.highlightRadius,
                color: effectFrame.effects.highlightColor,
                shape: effectFrame.effects.highlightShape,
                borderWidth: effectFrame.effects.highlightBorderWidth,
                fillOpacity: effectFrame.effects.highlightFillOpacity,
                in: context
            )
        }

        // The laser paints above the other pointer effects: its tail fades
        // in screen space through the same matrix, and the frame buffer
        // clips whatever spills past the window edge.
        if effectFrame.effects.isLaserEnabled {
            let trail = effectFrame.laserTrail.map { sample in
                (
                    point: CGPoint(x: sample.point.x, y: sample.point.y),
                    at: sample.at
                )
            }
            CursorEffectRenderer.drawLaserTrail(
                trail,
                at: Date(),
                color: effectFrame.effects.laserColor,
                radius: effectFrame.effects.laserRadius,
                keep: windowCGRect,
                in: context
            )
        }
        if effectFrame.effects.isLaserEnabled, isCursorHere, let cursor = cursorCGPoint {
            CursorEffectRenderer.drawLaserDot(
                at: cursor,
                color: effectFrame.effects.laserColor,
                radius: effectFrame.effects.laserRadius,
                in: context
            )
        }

        if !effectFrame.clicks.isEmpty {
            let now = Date()
            // The ripple may spill past the window edge, hence the
            // generous margin: a click just outside the window still shows
            // through as a partial arc, on screen and on tape alike.
            let margin = effectFrame.effects.highlightRadius * 2
            let rippleRect = CGRect(
                x: contentFrame.minX - margin,
                y: contentFrame.minY - margin,
                width: contentFrame.width + margin * 2,
                height: contentFrame.height + margin * 2
            )
            for click in effectFrame.clicks {
                let center = CGPoint(x: click.point.x, y: click.point.y)
                guard rippleRect.contains(center) else { continue }
                CursorEffectRenderer.drawRipple(
                    center: center,
                    startedAt: click.startedAt,
                    at: now,
                    color: effectFrame.effects.highlightColor,
                    highlightRadius: effectFrame.effects.highlightRadius,
                    highlightBorderWidth: effectFrame.effects.highlightBorderWidth,
                    isRight: click.isRight,
                    in: context
                )
            }
        }
        return target
    }

    /// Copies a frame buffer byte-for-byte into fresh memory we own so the
    /// burn-in never draws into an SCStream-pool buffer. Returns `nil` when
    /// the allocation or the copy fails, and the caller then burns in
    /// place.
    private static func makeCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        var copy: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &copy
        ) == kCVReturnSuccess, let copy else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard
            let sourceBase = CVPixelBufferGetBaseAddress(source),
            let copyBase = CVPixelBufferGetBaseAddress(copy)
        else {
            return nil
        }

        // Rows may be padded differently between the pool buffer and the
        // fresh one, so the copy walks row by row unless both strides
        // agree — then one memcpy suffices.
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let copyStride = CVPixelBufferGetBytesPerRow(copy)
        let rowBytes = width * 4
        if sourceStride == copyStride {
            memcpy(copyBase, sourceBase, sourceStride * height)
        } else {
            for row in 0..<height {
                memcpy(
                    copyBase.advanced(by: row * copyStride),
                    sourceBase.advanced(by: row * sourceStride),
                    rowBytes
                )
            }
        }
        return copy
    }

    private var stream: SCStream?
    private var isRunning = false
}
