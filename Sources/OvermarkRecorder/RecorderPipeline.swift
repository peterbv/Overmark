import AVFoundation
import CoreMedia
import Foundation
import OvermarkCore

/// The file-writing half of the recorder.
///
/// Takes the live pixel frames from `ScreenCaptureKit` and the (optional) PCM
/// buffers from the microphone and muxes them into a single `.mov` file with
/// one pass through `AVAssetWriter`.
///
/// Threading: the pipeline owns one serial queue and every mutation happens
/// there. The video source hands the same queue to `SCStream`, so the frame
/// callback runs *on* this queue and never has to hop; the microphone source
/// hops in with a boxed buffer. The class is `@unchecked Sendable` because
/// that confinement is by queue, not by actor.
final class RecorderPipeline: @unchecked Sendable {
    /// Outcome of a completed recording.
    struct Summary: Sendable {
        var url: URL
        /// Presentation timestamps of the first and last buffers, when any
        /// frame arrived at all.
        var firstTime: CMTime?
        var lastTime: CMTime?
        /// Frames actually appended to the media track.
        var videoFramesAppended: Int
        /// Frames discarded because the encoder could not keep up.
        var videoFramesDropped: Int
        /// Audio sample buffers appended.
        var audioBuffersAppended: Int
        /// Audio sample buffers discarded because they arrived before the
        /// session's start time.
        var audioBuffersDropped: Int
        /// The failure, if the writer rejected the file or an append.
        var error: Error?
        /// A screen-stream break; the captured prefix is still on disk.
        var streamFailure: Error?

        /// The captured duration, when any frame arrived.
        var duration: CMTime? {
            guard let firstTime, let lastTime, lastTime.isNumeric, lastTime >= firstTime else { return nil }
            return lastTime - firstTime
        }
    }

    /// Serialized domain for every pipeline mutation.
    ///
    /// `ScreenRecordingSource` hands this same queue to `SCStream` as its
    /// sample-handling queue, which is what makes frame callbacks append on
    /// the spot. Other sources hop in.
    let callbackQueue = DispatchQueue(label: "com.overmark.recorder.pipeline")

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let frameInterval: CMTime

    /// The source time the session was started with; appends below it are
    /// dropped to keep the mux coherent.
    private var sessionStart: CMTime?
    /// The largest video timestamp and audio timestamp appended so far.
    private var lastVideoTime: CMTime?
    private var lastAudioTime: CMTime?
    private var firstTime: CMTime?
    private var videoFramesAppended = 0
    private var videoFramesDropped = 0
    private var audioBuffersAppended = 0
    private var audioBuffersDropped = 0
    private var isFinalized = false
    private(set) var failure: Error?
    /// A stream-level break (display removed, capture denied mid-run). The
    /// file still covers everything captured before it, so it is reported
    /// next to the summary instead of discarding the run.
    private var streamBreak: Error?

    /// Creates the writer and its two tracks at `destination`.
    ///
    /// - Parameters:
    ///   - destination: The `.mov` file to write. The parent folder must exist.
    ///   - pixelWidth/pixelHeight: The capture resolution in pixels.
    ///   - frameRate: Frames per second; drives the default frame duration.
    ///   - codec: H.264 or HEVC.
    ///   - includesAudio: Whether an audio track is created. The track starts
    ///     empty; samples fill it once the microphone source is running.
    init(destination: URL, pixelWidth: Int, pixelHeight: Int, frameRate: Int, codec: RecordingCodec, includesAudio: Bool) throws {
        frameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.metadata = [
            Self.creatorMetadata("Overmark"),
        ]

        // A bit-rate rule of thumb: ~0.12 bits per pixel per frame yields
        // crisp annotation strokes on H.264 without ballooning file size.
        let bitsPerPixelPerFrame: Double = codec == .hevc ? 0.085 : 0.12
        let averageBitRate = max(
            2_000_000,
            Int(Double(pixelWidth * pixelHeight) * Double(frameRate) * bitsPerPixelPerFrame)
        )

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.cannotAddVideoTrack
        }
        writer.add(videoInput)
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )

        if includesAudio {
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 160_000,
            ])
            if let audioInput {
                audioInput.expectsMediaDataInRealTime = true
                guard writer.canAdd(audioInput) else {
                    throw RecorderError.cannotAddAudioTrack
                }
                writer.add(audioInput)
            }
        } else {
            audioInput = nil
        }
    }

    private static func creatorMetadata(_ creator: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierCreator
        item.value = creator as NSString
        return item
    }

    enum RecorderError: LocalizedError, Sendable {
        case cannotAddVideoTrack
        case cannotAddAudioTrack
        case cannotStartWriting(String)
        case appendRejected(String)
        case wroteNothing

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoTrack: "Could not create the video track."
            case .cannotAddAudioTrack: "Could not create the audio track."
            case .cannotStartWriting(let detail): "Could not start writing the recording: \(detail)"
            case .appendRejected(let detail): "The recorder rejected a frame: \(detail)"
            case .wroteNothing: "The recording ended up empty."
            }
        }
    }

    // MARK: - Appending

    /// One screen frame crossing into the pipeline's queue from another
    /// thread. The box is `@unchecked Sendable` because the frame pointer is
    /// only touched on the pipeline queue after the hop.
    private struct PixelFrame: @unchecked Sendable {
        var pixelBuffer: CVPixelBuffer
        var time: CMTime
    }

    /// One audio sample buffer crossing the same boundary.
    private struct AudioFrame: @unchecked Sendable {
        var sampleBuffer: CMSampleBuffer
    }

    /// Appends one screen frame delivered by the stream.
    ///
    /// `ScreenRecordingSource` hands `callbackQueue` to `SCStream`, so this
    /// runs on the pipeline's serial queue with no hop. Frames are dropped
    /// when the encoder cannot keep up: a presentation must never stall the
    /// whole Mac.
    func appendScreenFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        dispatchPrecondition(condition: .onQueue(callbackQueue))
        append(PixelFrame(pixelBuffer: pixelBuffer, time: presentationTime))
    }

    /// Appends one microphone sample buffer produced off the render thread.
    func appendAudioSampleFrame(_ sampleBuffer: CMSampleBuffer) {
        let frame = AudioFrame(sampleBuffer: sampleBuffer)
        callbackQueue.async {
            self.appendAudio(frame)
        }
    }

    private func append(_ frame: PixelFrame) {
        guard failure == nil, !isFinalized else { return }

        if !writer.startWritingIfNeeded(presentationTime: frame.time) {
            // Same failure reason as the one the writer reported.
            failure = writer.error
            return
        }
        if sessionStart == nil {
            sessionStart = frame.time
            writer.startSession(atSourceTime: frame.time)
        }
        guard frame.time >= (sessionStart ?? .invalid) else { return }

        // The stream paces frames (`minimumFrameInterval`); when the
        // encoder momentarily cannot keep up, a frame is dropped rather
        // than buffered — a presentation must never stall the whole Mac,
        // and the drop count surfaces it.
        guard videoInput.isReadyForMoreMediaData else {
            videoFramesDropped += 1
            return
        }
        if videoAdaptor.append(frame.pixelBuffer, withPresentationTime: frame.time) {
            videoFramesAppended += 1
            lastVideoTime = frame.time
            firstTime = firstTime ?? frame.time
        } else {
            videoFramesDropped += 1
            if let error = writer.error {
                failure = RecorderError.appendRejected("\(error)")
            }
        }
    }

    /// Appends one screen frame from any thread (hops onto the pipeline
    /// queue; used by tests and any future source that is not the stream).
    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let frame = PixelFrame(pixelBuffer: pixelBuffer, time: presentationTime)
        callbackQueue.async {
            self.append(frame)
        }
    }

    private func appendAudio(_ frame: AudioFrame) {
        guard let audioInput else { return }
        let sampleBuffer = frame.sampleBuffer

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !writer.startWritingIfNeeded(presentationTime: time) {
            failure = writer.error
            return
        }
        // The session starts with the first video frame; when audio runs
        // alone (a dead display stream) it anchors the session instead —
        // a voice-only file beats a lost presentation.
        if sessionStart == nil {
            sessionStart = time
            writer.startSession(atSourceTime: time)
        }
        guard time >= (sessionStart ?? .invalid) else {
            audioBuffersDropped += 1
            return
        }
        guard audioInput.isReadyForMoreMediaData else {
            audioBuffersDropped += 1
            return
        }
        if audioInput.append(sampleBuffer) {
            audioBuffersAppended += 1
            lastAudioTime = time
            firstTime = firstTime ?? time
        } else {
            audioBuffersDropped += 1
            if let error = writer.error {
                failure = RecorderError.appendRejected("\(error)")
            }
        }
    }

    /// Records a stream-level failure, arriving from `stream(_:didStopWithError:)`.
    func note(streamFailure: Error) {
        callbackQueue.async {
            guard self.streamBreak == nil else { return }
            self.streamBreak = streamFailure
        }
    }

    // MARK: - Finalizing

    /// Stops appending, closes the file and returns a summary of the run.
    func finish() async -> Summary {
        await withCheckedContinuation { continuation in
            callbackQueue.async {
                guard !self.isFinalized else {
                    continuation.resume(returning: self.summarize(url: URL(fileURLWithPath: "/dev/null")))
                    return
                }
                self.isFinalized = true

                let url = self.writer.outputURL
                // Close both tracks with a small tail so the last frame is
                // never truncated at exactly its own timestamp.
                let tail = self.frameInterval
                if let sessionStart = self.sessionStart {
                    let last = max(
                        self.lastVideoTime ?? sessionStart,
                        self.lastAudioTime ?? sessionStart
                    )
                    self.writer.endSession(atSourceTime: CMTimeMaximum(last + tail, sessionStart))
                }

                self.videoInput.markAsFinished()
                self.audioInput?.markAsFinished()

                self.writer.finishWriting {
                    if self.writer.status == .failed {
                        self.failure = self.failure ?? self.writer.error
                    }
                    continuation.resume(returning: self.summarize(url: url))
                }
            }
        }
    }

    private func summarize(url: URL) -> Summary {
        var last: CMTime?
        if let video = lastVideoTime, let audio = lastAudioTime {
            last = CMTimeMaximum(video, audio)
        } else {
            last = lastVideoTime ?? lastAudioTime
        }
        return Summary(
            url: url,
            firstTime: firstTime,
            lastTime: last,
            videoFramesAppended: videoFramesAppended,
            videoFramesDropped: videoFramesDropped,
            audioBuffersAppended: audioBuffersAppended,
            audioBuffersDropped: audioBuffersDropped,
            error: failure ?? (videoFramesAppended == 0 && audioBuffersAppended == 0 ? RecorderError.wroteNothing : nil),
            streamFailure: streamBreak
        )
    }
}

/// The one "smart" chunk of `AVAssetWriter` start logic, named so the intent
/// reads instead of nesting calls.
private extension AVAssetWriter {
    /// Starts writing if needed. Returns `false` — with `error` set — when
    /// the file could not be opened at all.
    func startWritingIfNeeded(presentationTime: CMTime) -> Bool {
        switch status {
        case .unknown:
            if startWriting() { return true }
            return false
        case .writing:
            return true
        default:
            return false
        }
    }
}
