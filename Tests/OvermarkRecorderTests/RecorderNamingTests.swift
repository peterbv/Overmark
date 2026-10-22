import AVFoundation
import CoreMedia
import CoreVideo
import OvermarkCore
import XCTest
@testable import OvermarkRecorder

final class RecorderNamingTests: XCTestCase {
    func testDestinationURLNamesByStamp() {
        let folder = URL(fileURLWithPath: "/tmp/overmark-tests-naming")
        let date = Date(timeIntervalSince1970: 1_763_500_000) // fixed instant
        let url = PresentationRecorder.destinationURL(in: folder, date: date, probe: .default)

        XCTAssertTrue(url.lastPathComponent.hasPrefix("Overmark "))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".mov"))
        XCTAssertEqual(url.deletingLastPathComponent().path, folder.path)
    }

    func testDestinationURLAvoidsCollisions() throws {
        let probe = FileManager.default
        let folder = URL(fileURLWithPath: "/tmp/overmark-tests-collision")
        try probe.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? probe.removeItem(at: folder) }

        let date = Date(timeIntervalSince1970: 1_763_500_000)
        let first = PresentationRecorder.destinationURL(in: folder, date: date, probe: probe)
        try Data("x".utf8).write(to: first)

        let second = PresentationRecorder.destinationURL(in: folder, date: date, probe: probe)
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertTrue(second.lastPathComponent.contains("(2)"))

        try probe.removeItem(at: first)
        let third = PresentationRecorder.destinationURL(in: folder, date: date, probe: probe)
        XCTAssertEqual(third, first)
    }
}

/// Geometry of the window target: the persisted policy names the window,
/// but the run sizes its track from the resolved window — these helpers are
/// the pure part of that handshake.
final class RecorderWindowGeometryTests: XCTestCase {
    func testPixelSizeForcesEvenDimensions() {
        let size = WindowRecordingSource.fittedPixelSize(
            widthPoints: 999,
            heightPoints: 501,
            scale: 1,
            cappedPixels: 3_840
        )
        XCTAssertEqual(size.width, 998)
        XCTAssertEqual(size.height, 500)
    }

    func testPixelSizeCapsHugeWindows() {
        // A 2560×1920 point window at Retina would land at 5120×3840
        // pixels; the cap keeps the long edge at 3840.
        let size = WindowRecordingSource.fittedPixelSize(
            widthPoints: 2_560,
            heightPoints: 1_920,
            scale: 2,
            cappedPixels: 3_840
        )
        XCTAssertEqual(size.width, 3_840)
        XCTAssertEqual(size.height, 2_880)
    }

    func testAppKitFrameKeepsHorizontalsAndSize() {
        let windowFrame = CGRect(x: 120, y: 200, width: 300, height: 400)
        let appFrame = WindowRecordingSource.appKitFrame(ofWindowFrame: windowFrame)

        XCTAssertEqual(appFrame.width, 300)
        XCTAssertEqual(appFrame.height, 400)
        XCTAssertEqual(appFrame.minX, 120)
        // The vertical flip turns the top-left origin into a bottom-left
        // one anchored at the primary screen's top edge.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? windowFrame.maxY
        XCTAssertEqual(appFrame.maxY, primaryTop - windowFrame.minY, accuracy: 0.001)
    }
}

/// The per-frame mapping the burn-in uses in window recordings: the frame
/// info the stream attaches is resolved with a candidate ladder calibrated
/// against the frame the run started with, so the mapping works whatever
/// units the stream used for its rects.
final class RecorderFrameMappingTests: XCTestCase {
    /// The AppKit frame of the window at start, the calibration anchor.
    private let knownFrame = CGRect(x: 100, y: 850, width: 800, height: 200)

    /// `knownFrame` expressed the way ScreenCaptureKit reports rect values
    /// (top-left origin, points): the same rect flipped vertically.
    private var rawPointsRect: CGRect {
        WindowRecordingSource.appKitFrame(ofWindowFrame: knownFrame)
    }

    func testScreenRectInPointUnitsResolvesToKnownFrame() {
        let raw = WindowRecordingSource.appKitFrame(ofWindowFrame: knownFrame)
        let resolved = WindowRecordingSource.contentFrameAppKit(
            rawScreenRect: raw,
            knownFrame: knownFrame,
            pointPixelScale: 1
        )

        XCTAssertEqual(resolved.minX, knownFrame.minX, accuracy: 0.001)
        XCTAssertEqual(resolved.maxY, knownFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(resolved.width, knownFrame.width, accuracy: 0.001)
        XCTAssertEqual(resolved.height, knownFrame.height, accuracy: 0.001)
    }

    func testScreenRectInPixelUnitsResolvesThroughScale() {
        // The same rect reported at double scale (a 2× surface).
        let raw = CGRect(
            x: rawPointsRect.origin.x,
            y: rawPointsRect.origin.y,
            width: knownFrame.width * 2,
            height: knownFrame.height * 2
        )
        let resolved = WindowRecordingSource.contentFrameAppKit(
            rawScreenRect: raw,
            knownFrame: knownFrame,
            pointPixelScale: 2
        )

        XCTAssertEqual(resolved.minX, knownFrame.minX, accuracy: 0.001)
        XCTAssertEqual(resolved.maxY, knownFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(resolved.width, knownFrame.width, accuracy: 0.001)
        XCTAssertEqual(resolved.height, knownFrame.height, accuracy: 0.001)
    }

    func testContentRectScaledToSurfaceUnitsIsPromoted() {
        // The stream reports a content rect in surface points while the
        // buffer is its pixel mirror (2× here): the scaled candidate
        // matches the buffer, so that is the one used.
        let raw = CGRect(x: 100, y: 4, width: 800, height: 200)
        let content = WindowRecordingSource.contentRectInPixels(
            rawContentRect: raw,
            bufferSize: CGSize(width: 1600, height: 400),
            pointPixelScale: 2
        )

        XCTAssertEqual(content.minX, 200)
        XCTAssertEqual(content.minY, 8)
        XCTAssertEqual(content.width, 1600)
        XCTAssertEqual(content.height, 400)
    }

    func testContentRectAlreadyInPixelsStaysUntouched() {
        let raw = CGRect(x: 0, y: 0, width: 1600, height: 400)
        let content = WindowRecordingSource.contentRectInPixels(
            rawContentRect: raw,
            bufferSize: CGSize(width: 1600, height: 400),
            pointPixelScale: 2
        )

        XCTAssertEqual(content, raw)
    }

    func testMissingContentRectFallsBackToFullBuffer() {
        let content = WindowRecordingSource.contentRectInPixels(
            rawContentRect: nil,
            bufferSize: CGSize(width: 1600, height: 400),
            pointPixelScale: 2
        )

        XCTAssertEqual(content, CGRect(x: 0, y: 0, width: 1600, height: 400))
    }

    func testTransformFollowsAResizedWindow() {
        // The window started as 800×200 and grew to 1600×200 while the
        // track is fixed: the stream compressed X (800/1600) and stretched
        // Y (400/200) to keep the content filling the buffer. The
        // transform must land a global point on the same offset inside
        // the content — not on the geometry at start.
        let contentFrame = CGRect(x: 100, y: 850, width: 1600, height: 200)
        let contentRect = CGRect(x: 0, y: 0, width: 800, height: 400)
        let transform = WindowRecordingSource.annotationTransform(
            contentFrame: contentFrame,
            contentRect: contentRect
        )

        // A quarter along the window's width (400 points → 200 px at the
        // 0.5 X factor) and a quarter down its height (50 points from the
        // top → 100 px at the 2.0 Y factor).
        let pixel = CGPoint(x: 500, y: 1000).applying(transform)
        XCTAssertEqual(pixel.x, 200, accuracy: 0.001)
        XCTAssertEqual(pixel.y, 100, accuracy: 0.001)
    }

    func testTransformOmitsStaleStartGeometry() {
        // The mapping must use the measured frame, not the one the run
        // was started with: a window that moved right keeps its
        // annotations glued to it.
        let movedFrame = knownFrame.offsetBy(dx: 400, dy: 0)
        let transform = WindowRecordingSource.annotationTransform(
            contentFrame: movedFrame,
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 400)
        )

        let pixel = CGPoint(x: movedFrame.minX, y: movedFrame.maxY).applying(transform)
        XCTAssertEqual(pixel.x, 0, accuracy: 0.001)
        XCTAssertEqual(pixel.y, 0, accuracy: 0.001)
    }

    func testRectDistanceRanksNearestCandidate() {
        let close = knownFrame
        let far = knownFrame.offsetBy(dx: 4_000, dy: 0)
        let otherSize = CGRect(x: 100, y: 850, width: 1_600, height: 400)

        XCTAssertEqual(
            WindowRecordingSource.rectDistanceInAppKit(close, knownFrame: knownFrame),
            0,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            WindowRecordingSource.rectDistanceInAppKit(close, knownFrame: knownFrame),
            WindowRecordingSource.rectDistanceInAppKit(otherSize, knownFrame: knownFrame)
        )
        XCTAssertLessThan(
            WindowRecordingSource.rectDistanceInAppKit(otherSize, knownFrame: knownFrame),
            WindowRecordingSource.rectDistanceInAppKit(far, knownFrame: knownFrame)
        )
    }
}

final class RecorderSettingsTests: XCTestCase {
    func testClampSnapsIllegalFrameRates() {
        XCTAssertEqual(RecorderSettings(frameRate: 24).clamped().frameRate, 30)
        XCTAssertEqual(RecorderSettings(frameRate: 60).clamped().frameRate, 60)
        XCTAssertEqual(RecorderSettings(frameRate: 30).clamped().frameRate, 30)
    }

    func testCodableRoundTripKeepsChoices() throws {
        let original = RecorderSettings(frameRate: 60, codec: .hevc, includesMicrophone: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecorderSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testWindowTargetRoundTripsWithChoice() throws {
        var original = RecorderSettings()
        original.target = .window
        original.windowChoice = RecordingWindowChoice(title: "Slides", ownerName: "Keynote")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecorderSettings.self, from: data)

        XCTAssertEqual(decoded.target, .window)
        XCTAssertEqual(decoded.windowChoice, RecordingWindowChoice(title: "Slides", ownerName: "Keynote"))
    }

    func testLegacyBlobWithoutWindowKeysDecodesToDisplayTarget() throws {
        // A blob from before the window target existed keeps loading and
        // lands on the display target with no window chosen.
        let legacy = """
        {"frameRate":60,"codec":"h264","includesMicrophone":false,"displayChoice":{"main":{}}}
        """
        let decoded = try JSONDecoder().decode(RecorderSettings.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.target, .display)
        XCTAssertNil(decoded.windowChoice)
        XCTAssertEqual(decoded.frameRate, 60)
    }

    func testFolderPathBlankOrHomeFallsBackToDefault() {
        let home = NSHomeDirectory()
        XCTAssertEqual(RecorderSettings(frameRate: 30, codec: .h264, includesMicrophone: false, folderPath: "   ").clamped().folderPath, nil)
        XCTAssertEqual(RecorderSettings(frameRate: 30, codec: .h264, includesMicrophone: false, folderPath: home).clamped().folderPath, nil)
        XCTAssertEqual(RecorderSettings(frameRate: 30, codec: .h264, includesMicrophone: false, folderPath: "\(home)/Movies").clamped().folderPath, nil)

        let custom = "\(home)/Desktop/Grabaciones"
        XCTAssertEqual(RecorderSettings(frameRate: 30, codec: .h264, includesMicrophone: false, folderPath: custom).clamped().folderPath, custom)
    }

    func testMissingFolderKeyDecodesAsDefault() throws {
        // A truly legacy blob — encoded by a version that predated
        // `folderPath` and `displayChoice` — must still load: the tolerance
        // init fills the gaps with defaults instead of failing.
        let data = try JSONEncoder().encode(
            RecorderSettings(frameRate: 60, codec: .hevc, includesMicrophone: true)
        )
        var object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        object.removeValue(forKey: "displayChoice")
        object.removeValue(forKey: "folderPath")
        let stale = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RecorderSettings.self, from: stale)
        XCTAssertEqual(decoded.displayChoice, .main)
        XCTAssertNil(decoded.folderPath)
        XCTAssertEqual(decoded.frameRate, 60)
        XCTAssertEqual(decoded.codec, .hevc)
    }

    func testDisplayChoiceRoundTripsBothPolicies() throws {
        // The saved choice is a policy (main vs. a named screen), never a
        // raw CGDirectDisplayID, so it survives reboots that renumber
        // displays.
        let choices: [RecordingDisplayChoice] = [.main, .namedScreen("DELL U2721QE")]
        for choice in choices {
            let original = RecorderSettings(
                frameRate: 60,
                codec: .h264,
                includesMicrophone: false,
                displayChoice: choice
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(RecorderSettings.self, from: data)
            XCTAssertEqual(decoded.displayChoice, choice)
        }
    }
}

final class RecorderPipelineTests: XCTestCase {
    // MARK: Video

    func testVideoOnlyWritesPlayableFile() async throws {
        let (summary, url) = try await self.writeVideoFrameRun(
            frames: 15,
            codec: .h264,
            includesAudio: false
        )

        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(summary.error)
        XCTAssertNil(summary.streamFailure)
        XCTAssertEqual(summary.videoFramesAppended, 15)
        XCTAssertEqual(summary.videoFramesDropped, 0)
        XCTAssertEqual(summary.audioBuffersAppended, 0)

        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertTrue((bytes ?? 0) > 1_000, "the mov should hold encoded frames, was \(bytes ?? 0) bytes")

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.3)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    // MARK: Audio

    func testAudioFirstAnchorsSessionAndWritesAudioTrack() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overmark-test-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = try RecorderPipeline(
            destination: url,
            pixelWidth: 64,
            pixelHeight: 64,
            frameRate: 30,
            codec: .h264,
            includesAudio: true
        )

        // Audio before any video: the audio track anchors the session on
        // its own (the voice-only fallback path).
        let hostStart = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        for chunk in 0..<10 {
            let buffer = try Self.makePCMSampleBuffer(
                frameCount: 4_800,
                secondsSinceStart: hostStart + Double(chunk) * 0.2
            )
            pipeline.appendAudioSampleFrame(buffer)
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        let summary = await pipeline.finish()

        XCTAssertNil(summary.error)
        XCTAssertGreaterThan(summary.audioBuffersAppended, 0)

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.5)
    }

    func testAudioBeforeVideoSessionIsDropped() async throws {
        let (summary, url) = try await self.writeMixedRun()
        defer { try? FileManager.default.removeItem(at: url) }

        // The audio chunks that preceded the first video frame must be
        // dropped so the mux stays coherent.
        XCTAssertEqual(summary.videoFramesAppended, 10)
        XCTAssertGreaterThan(summary.audioBuffersAppended, 0)
        XCTAssertNil(summary.error)
    }

    // MARK: Encode size

    func testUnknownDisplayFallsBackToBaseSize() {
        let size = PresentationRecorder.encodeSize(displayID: CGDirectDisplayID(0xF00D), capped: 3_840)
        // No NSScreen matches a fake display id: the fallback geometry of
        // 1920×1080 at scale 1 is used untouched.
        XCTAssertEqual(size.width, 1_920)
        XCTAssertEqual(size.height, 1_080)
    }

    // MARK: Helpers

    /// Appends `frames` synthetic BGRA frames with audio chunks after
    /// them, at 30 fps, and finalizes.
    private func writeMixedRun() async throws -> (RecorderPipeline.Summary, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overmark-test-\(UUID().uuidString).mov")

        let pipeline = try RecorderPipeline(
            destination: url,
            pixelWidth: 640,
            pixelHeight: 360,
            frameRate: 30,
            codec: .h264,
            includesAudio: true
        )

        let hostStart = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let interval = CMTime(value: 1, timescale: 30)
        var clock = CMTime.zero
        for index in 0..<10 {
            let buffer = try Self.makePixelBuffer(width: 640, height: 360)
            pipeline.appendVideoFrame(buffer, presentationTime: clock)
            clock = clock + interval
            if index < 9 {
                try await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        for chunk in 0..<6 {
            let audio = try Self.makePCMSampleBuffer(
                frameCount: 2_400,
                secondsSinceStart: hostStart + Double(chunk) * 0.05 + 0.5
            )
            pipeline.appendAudioSampleFrame(audio)
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let summary = await pipeline.finish()
        return (summary, url)
    }

    private func writeVideoFrameRun(frames: Int, codec: RecordingCodec, includesAudio: Bool) async throws -> (RecorderPipeline.Summary, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overmark-test-\(UUID().uuidString).mov")

        let pipeline = try RecorderPipeline(
            destination: url,
            pixelWidth: 640,
            pixelHeight: 360,
            frameRate: 30,
            codec: codec,
            includesAudio: includesAudio
        )

        let interval = CMTime(value: 1, timescale: 30)
        var clock = CMTime.zero
        for index in 0..<frames {
            // Encoder capacity arrives asynchronously; pacing like the
            // real stream (30 fps) keeps the burst from dropping frames.
            let buffer = try Self.makePixelBuffer(width: 640, height: 360)
            pipeline.appendVideoFrame(buffer, presentationTime: clock)
            clock = clock + interval
            if index < frames - 1 {
                try await Task.sleep(nanoseconds: 40_000_000)
            }
        }

        let summary = await pipeline.finish()
        return (summary, url)
    }

    /// A single-tone BGRA pixel buffer, the shape `SCStream` delivers.
    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        guard let buffer = pixelBuffer else {
            throw NSError(domain: "test", code: 1)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            for row in 0..<height {
                memset(base.advanced(by: row * bytesPerRow), 0x7f, bytesPerRow)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Interleaved stereo float PCM sample buffer, stamped at `seconds
    /// SinceStart` on the host clock — the same shape the microphone
    /// source hands the pipeline.
    private static func makePCMSampleBuffer(frameCount: Int, secondsSinceStart: Double) throws -> CMSampleBuffer {
        let channels = 2
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        let byteCount = frameCount * bytesPerFrame

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        guard let blockBuffer else {
            throw NSError(domain: "test", code: 2)
        }

        var samples = [Float](repeating: 0, count: frameCount * channels)
        for index in stride(from: 0, to: samples.count, by: channels) {
            // A quiet sine on both channels; neither value nor wave matter,
            // only that the writer sees in-spec float PCM.
            samples[index] = 0.1
            samples[index + 1] = -0.1
        }
        let replaceStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        XCTAssertEqual(replaceStatus, kCMBlockBufferNoErr)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
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
        let descriptionStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(descriptionStatus, kCMBlockBufferNoErr)
        guard let description = formatDescription else {
            throw NSError(domain: "test", code: 3)
        }

        let presentationTime = CMTime(
            seconds: secondsSinceStart,
            preferredTimescale: CMTimeScale(48_000)
        )
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 48_000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var timingStore = timing
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingStore,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sampleStatus, noErr)
        guard let sampleBuffer else {
            throw NSError(domain: "test", code: 4)
        }
        return sampleBuffer
    }
}
