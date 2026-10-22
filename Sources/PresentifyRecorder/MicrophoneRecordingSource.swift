import AVFoundation
import CoreMedia
import Foundation

/// The audio half of the presentation recorder.
///
/// Captures the microphone with `AVAudioEngine`'s input tap, resamples the
/// device's native format to 48 kHz and hands `CMSampleBuffer`s of linear
/// PCM to the pipeline, whose audio track encodes them to AAC.
///
/// Timestamps: audio must share a timeline with the screen frames. The first
/// tap buffer is stamped with the host-time clock — the same clock
/// `SCStream` stamps video with — and every later buffer keeps counting
/// converted frames on top of it, so a 48 kHz audio timeline rides on the
/// host clock and voice lines up with picture even if the device resamples
/// or disconnects mid-session.
final class MicrophoneRecordingSource: @unchecked Sendable {
    private let pipeline: RecorderPipeline
    private var box: BufferBox?
    private var engine: AVAudioEngine?

    init(pipeline: RecorderPipeline) {
        self.pipeline = pipeline
    }

    /// Starts the tap. The microphone permission must have been granted by
    /// the time this runs — checking it lives in the app layer, which keeps
    /// this class free of TCC concerns.
    func start() throws {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw RecorderMicrophoneError.noInputDeviceFormat
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: min(2, max(1, sourceFormat.channelCount)),
            interleaved: false
        ) ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw RecorderMicrophoneError.cannotResample
        }

        let box = BufferBox(pipeline: pipeline, converter: converter, format: targetFormat)
        // The tap runs on the engine's render thread; the box converts the
        // buffer there (cheap: ~80 ms of audio at 4 096 frames) and pushes
        // the result to the pipeline, which hops it onto its serial queue.
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { tapBuffer, _ in
            box.convert(tapBuffer)
        }

        engine.prepare()
        try engine.start()

        self.engine = engine
        self.box = box
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.box = nil
    }
}

enum RecorderMicrophoneError: LocalizedError {
    case noInputDeviceFormat
    case cannotResample

    var errorDescription: String? {
        switch self {
        case .noInputDeviceFormat: "The microphone gave no usable format."
        case .cannotResample: "The microphone's format could not be resampled."
        }
    }
}

/// Converts tap buffers to the 48 kHz target format and forwards them to
/// the pipeline as sample buffers.
///
/// All mutable state is touched only from the tap's render thread, which
/// calls `convert` serially; the pipeline hop is the only other domain, and
/// it happens through the pipeline's boxed append.
private final class BufferBox: @unchecked Sendable {
    private let pipeline: RecorderPipeline
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    /// Host time stamped on the first buffer; later buffers count frames
    /// from there so timestamps can never go backwards when the device
    /// resamples or disconnects mid-session.
    private var timelineStart: CMTime?
    private var totalFrames: AVAudioFramePosition = 0

    init(pipeline: RecorderPipeline, converter: AVAudioConverter, format: AVAudioFormat) {
        self.pipeline = pipeline
        self.converter = converter
        self.format = format
    }

    func convert(_ input: AVAudioPCMBuffer) {
        guard input.frameLength > 0 else { return }

        // Resample the device format (often 16 kHz mono built-in mics) to
        // the target 48 kHz, converting through the provider closure.
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var conversionError: NSError?
        var providedInput = false
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if providedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            outStatus.pointee = .haveData
            return input
        }
        guard status == .haveData, conversionError == nil, output.frameLength > 0 else { return }

        // Anchor the audio timeline on the host clock at the first buffer.
        if timelineStart == nil {
            timelineStart = Self.hostTimeNow()
        }
        // The presentation time of this buffer is the anchor plus how ever
        // many converted frames came before it, so the timeline advances
        // monotonically even if the device resamples or disconnects.
        guard let sampleBuffer = Self.makeSampleBuffer(
            from: output,
            format: format,
            timelineStart: timelineStart!,
            atFrameOffset: totalFrames
        ) else { return }
        totalFrames += AVAudioFramePosition(output.frameLength)
        pipeline.appendAudioSampleFrame(sampleBuffer)
    }

    private static func hostTimeNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        timelineStart: CMTime,
        atFrameOffset offset: AVAudioFramePosition
    ) -> CMSampleBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0, let floatChannelData = buffer.floatChannelData else { return nil }

        // The taps deliver non-interleaved float32; the sample buffer needs
        // one contiguous region, so interleave into it directly.
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        let byteCount = frames * bytesPerFrame

        // The block buffer owns its own allocation (memoryBlock == nil), so
        // the sample buffer's lifetime is bounded by the block itself and
        // not by this conversion call.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var interleaved = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                interleaved[frame * channels + channel] = floatChannelData[channel][frame]
            }
        }
        guard CMBlockBufferReplaceDataBytes(
            with: interleaved,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        ) == kCMBlockBufferNoErr else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == kCMBlockBufferNoErr, let formatDescription else { return nil }

        let presentationTime = CMTimeAdd(
            timelineStart,
            CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(format.sampleRate))
        )
        let timing: CMSampleTimingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var timingMutated = timing
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingMutated,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }
}
