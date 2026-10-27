import AppKit
import CoreMedia
import Foundation
import OvermarkCore

/// Orchestrates one presentation recording.
///
/// Owns the file name, the pipeline and the two sources (screen, optional
/// microphone). It stays free of UI and permission dialogs: the caller picks
/// the display, gathers the window numbers that must not be taped and has
/// already sorted Access out; this actor only worries about capture and
/// files, which keeps it testable headless.
public actor PresentationRecorder {
    /// Everything needed to start, decided by the caller.
    public struct Configuration: Sendable {
        /// The display the file captures — also the fallback target when a
        /// window recording cannot find its window.
        public var displayID: CGDirectDisplayID
        /// `NSWindow.windowNumber`s of app chrome that must not appear.
        public var excludedWindowNumbers: Set<Int>
        /// What and how to encode.
        public var settings: RecorderSettings
        /// The folder the `.mov` lands in. Must exist; the app layer
        /// creates it before calling.
        public var destinationFolder: URL
        /// When set, the recording follows this window instead of the
        /// display; annotations are burned into the frames because the
        /// overlay windows are not part of the target.
        public var windowChoice: RecordingWindowChoice?
        /// The annotations to burn in for window recordings, read fresh
        /// every frame (the presenter keeps drawing while the run goes on).
        /// The display recording does not need it: the overlay windows are
        /// on tape by themselves.
        public var annotationsProvider: @Sendable () -> [Annotation]
        /// The cursor-effect state to burn in for window recordings (ring,
        /// spotlight, lens, ripples), read fresh every frame. Return `nil` to
        /// skip the burn entirely; display recordings leave it unset because
        /// their effect windows are on tape by themselves.
        public var effectsProvider: @Sendable () -> CursorEffectFrame?

        public init(
            displayID: CGDirectDisplayID,
            excludedWindowNumbers: Set<Int>,
            settings: RecorderSettings,
            destinationFolder: URL,
            windowChoice: RecordingWindowChoice? = nil,
            annotationsProvider: @escaping @Sendable () -> [Annotation] = { [] },
            effectsProvider: @escaping @Sendable () -> CursorEffectFrame? = { nil }
        ) {
            self.displayID = displayID
            self.excludedWindowNumbers = excludedWindowNumbers
            self.settings = settings.clamped()
            self.destinationFolder = destinationFolder
            self.windowChoice = windowChoice
            self.annotationsProvider = annotationsProvider
            self.effectsProvider = effectsProvider
        }
    }

    /// The result of a stopped recording.
    public struct Outcome: Sendable {
        /// The written file. Once `stop` returns, the file is complete:
        /// appends are closed, the index is written and it is playable.
        public var url: URL
        /// The captured duration.
        public var duration: CMTime?
        public var videoFramesAppended: Int
        public var videoFramesDropped: Int
        public var audioBuffersAppended: Int
        /// A stream-level failure (display unplugged, capture revoked
        /// mid-run). The prefix that was captured is still complete on disk.
        public var streamFailure: Error?
    }

    /// The largest encode head this recorder will ask of an encoder: 4K UHD
    /// width is the safe ceiling for H.264 hardware engines, and a uniform
    /// cap keeps file sizes predictable across codec choices.
    static let maxEncodePixels = 3_840

    static let fileExtension = "mov"

    private var pipeline: RecorderPipeline?
    private var screenSource: ScreenRecordingSource?
    private var windowSource: WindowRecordingSource?
    private var microphoneSource: MicrophoneRecordingSource?

    public init() {}

    /// Names and opens the destination file up front, then starts the
    /// capture sources. Returns the path the recording will land at.
    public func start(_ configuration: Configuration, date: Date = Date.now) async throws -> URL {
        guard pipeline == nil else { throw RecorderRunError.alreadyRunning }

        let url = Self.destinationURL(in: configuration.destinationFolder, date: date)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let includesAudio = configuration.settings.includesMicrophone

        if let windowChoice = configuration.windowChoice {
            // The chosen window sizes the track: its frame at start decides
            // the encode resolution. A running writer cannot resize its
            // track, so the stream scales the window up and down into the
            // fixed track (`scalesToFit`) and the burn-in reads each
            // frame's geometry from the stream frame info instead — a
            // resized window keeps filling the video with its annotations
            // glued to it.
            let resolved = try await WindowRecordingSource.resolve(
                windowChoice,
                cappedPixels: Self.maxEncodePixels
            )
            let freshPipeline = try RecorderPipeline(
                destination: url,
                pixelWidth: resolved.pixelWidth,
                pixelHeight: resolved.pixelHeight,
                frameRate: configuration.settings.frameRate,
                codec: configuration.settings.codec,
                includesAudio: includesAudio
            )
            let window = WindowRecordingSource(
                pipeline: freshPipeline,
                annotationsProvider: configuration.annotationsProvider,
                effectsProvider: configuration.effectsProvider,
                windowFrame: resolved.appKitFrame
            )
            // The writer owns the destination file from here on: any
            // failing stage must tear the half-started run down, or a
            // broken start leaves streams running and an empty `.mov` in
            // the recordings folder.
            do {
                try await window.start(resolved, frameRate: configuration.settings.frameRate)
                let microphone = try makeMicrophoneSource(includesAudio: includesAudio, pipeline: freshPipeline)
                // The run is fully wired — publish it for stop() to drain.
                self.microphoneSource = microphone
                self.pipeline = freshPipeline
                self.windowSource = window
                return url
            } catch {
                await discardPartialRun(pipeline: freshPipeline, screen: nil, window: window, fileURL: url)
                throw error
            }
        }

        let encodeSize = Self.encodeSize(displayID: configuration.displayID, capped: Self.maxEncodePixels)
        let freshPipeline = try RecorderPipeline(
            destination: url,
            pixelWidth: encodeSize.width,
            pixelHeight: encodeSize.height,
            frameRate: configuration.settings.frameRate,
            codec: configuration.settings.codec,
            includesAudio: includesAudio
        )
        let screen = ScreenRecordingSource(pipeline: freshPipeline)
        do {
            try await screen.start(
                displayID: configuration.displayID,
                pixelWidth: encodeSize.width,
                pixelHeight: encodeSize.height,
                frameRate: configuration.settings.frameRate,
                excludedWindowNumbers: configuration.excludedWindowNumbers
            )
            let microphone = try makeMicrophoneSource(includesAudio: includesAudio, pipeline: freshPipeline)
            self.microphoneSource = microphone
            self.pipeline = freshPipeline
            self.screenSource = screen
            return url
        } catch {
            await discardPartialRun(pipeline: freshPipeline, screen: screen, window: nil, fileURL: url)
            throw error
        }
    }

    /// Wires the microphone tap in when the run asked for one. The source
    /// is handed back instead of stored, so a later failing stage of
    /// `start` can tear the whole run down without publishing anything.
    private func makeMicrophoneSource(
        includesAudio: Bool,
        pipeline: RecorderPipeline
    ) throws -> MicrophoneRecordingSource? {
        guard includesAudio else { return nil }
        let source = MicrophoneRecordingSource(pipeline: pipeline)
        do {
            try source.start()
        } catch {
            // The tap may already be installed on the engine it failed to
            // start; stop() releases everything the source created.
            source.stop()
            throw error
        }
        return source
    }

    /// Tears down a run whose start failed partway: the sources stop
    /// draining, the pipeline closes whatever landed in the file and the
    /// empty or truncated artifact is removed — a failed start leaves
    /// nothing behind.
    private func discardPartialRun(
        pipeline: RecorderPipeline,
        screen: ScreenRecordingSource?,
        window: WindowRecordingSource?,
        fileURL: URL
    ) async {
        await screen?.stop()
        await window?.stop()
        _ = await pipeline.finish()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Stops both sources, drains pending frames and closes the file.
    public func stop() async -> Outcome {
        // Sources first: stopping them before the pipeline lets every
        // already-delivered frame still land in the file.
        await screenSource?.stop()
        await windowSource?.stop()
        microphoneSource?.stop()
        screenSource = nil
        windowSource = nil
        microphoneSource = nil

        guard let pipeline else {
            // Stop without a running recording — the caller guards this,
            // so reaching here means a race with ESC; report an honest
            // nothing rather than crashing.
            return Outcome(
                url: URL(fileURLWithPath: "none"),
                duration: nil,
                videoFramesAppended: 0,
                videoFramesDropped: 0,
                audioBuffersAppended: 0,
                streamFailure: nil
            )
        }
        let summary = await pipeline.finish()
        self.pipeline = nil

        return Outcome(
            url: summary.url,
            duration: summary.duration,
            videoFramesAppended: summary.videoFramesAppended,
            videoFramesDropped: summary.videoFramesDropped,
            audioBuffersAppended: summary.audioBuffersAppended,
            streamFailure: summary.streamFailure
        )
    }

    // MARK: - Naming

    /// Picks the destination file name that does not collide with an older
    /// recording of the same second: `Overmark 2026-10-21 09-23-45.mov`.
    public static func destinationURL(in folder: URL, date: Date = Date.now, probe: FileManager = .default) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let stamp = formatter.string(from: date)

        var candidate = folder.appendingPathComponent("Overmark \(stamp).\(fileExtension)")
        var suffix = 2
        while probe.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("Overmark \(stamp) (\(suffix)).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }

    // MARK: - Encode size

    /// The encode resolution for a display, in pixels, clamped to
    /// `maxEncodePixels` on the long edge so 5K/6K heads fit H.264.
    static func encodeSize(displayID: CGDirectDisplayID, capped pixels: Int) -> (width: Int, height: Int) {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
        let scale = screen?.backingScaleFactor ?? 1
        let size = screen?.frame.size ?? CGSize(width: 1_920, height: 1_080)
        var width = Int((size.width * scale).rounded())
        var height = Int((size.height * scale).rounded())

        let largest = max(width, height)
        if largest > pixels {
            let factor = Double(pixels) / Double(largest)
            width = max(2, Int((Double(width) * factor).rounded()))
            height = max(2, Int((Double(height) * factor).rounded()))
        }
        return (width, height)
    }
}

enum RecorderRunError: LocalizedError {
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A recording is already active."
        }
    }
}
