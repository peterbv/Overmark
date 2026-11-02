import AppKit
import CoreGraphics
import Foundation
import OvermarkCore
import ScreenCaptureKit

/// Captures the contents of the screen.
///
/// Uses `ScreenCaptureKit`, the modern replacement for the deprecated
/// `CGDisplayCreateImage`. It requires the Screen Recording permission, which
/// the app checks before attempting a capture.
public actor ScreenCaptureService {
    /// A captured image of a single display.
    public struct DisplaySnapshot: Sendable {
        /// The image, in the display's own pixel space.
        public var image: CGImage
        /// The display this image came from.
        public var screen: ScreenFrame
        /// The id of the display this image came from.
        ///
        /// The id is what links a snapshot back to the overlay panel drawn
        /// for that display, so each panel can show its own screenshot.
        public var displayID: CGDirectDisplayID

        public init(
            image: CGImage,
            screen: ScreenFrame,
            displayID: CGDirectDisplayID
        ) {
            self.image = image
            self.screen = screen
            self.displayID = displayID
        }
    }

    /// The available displays, keyed by their ScreenCaptureKit display id.
    public struct DisplayInfo: Sendable {
        public var displayID: CGDirectDisplayID
        public var screen: ScreenFrame
        /// The width of the captured image in pixels.
        public var pixelWidth: Int
        /// The height of the captured image in pixels.
        public var pixelHeight: Int
    }

    public init() {}

    /// Whether the app currently holds the Screen Recording permission.
    public nonisolated func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests the Screen Recording permission, prompting the system dialog.
    ///
    /// - Returns: `true` if permission is granted once the request resolves.
    @discardableResult
    public func requestPermission() async -> Bool {
        if hasPermission() { return true }
        let granted = CGRequestScreenCaptureAccess()
        return granted || hasPermission()
    }

    /// Lists the displays currently attached to the system.
    public func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return content.displays.map { display in
            Self.describe(display)
        }
    }

    /// Captures a single display.
    ///
    /// - Parameter displayID: The display to capture.
    /// - Returns: The captured image, or `nil` if the display has gone away.
    public func capture(displayID: CGDirectDisplayID) async throws -> DisplaySnapshot? {
        // `SCShareableContent` can be expensive to enumerate (it snapshots
        // every window in the session), so the display is looked up from the
        // same content the exclusion list came from — one pass per capture.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return nil
        }
        return try await capture(display, excludingWindows: ownWindows(in: content))
    }

    /// Captures several displays with a single content enumeration.
    ///
    /// The requested ids are matched against one pass of
    /// `SCShareableContent`: displays that are no longer attached are
    /// skipped, exactly as `capture(displayID:)` returns `nil` for them.
    /// The order follows ScreenCaptureKit's display order.
    public func capture(displayIDs: [CGDirectDisplayID]) async throws -> [DisplaySnapshot] {
        guard !displayIDs.isEmpty else { return [] }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let excluded = ownWindows(in: content)
        var pending = Set(displayIDs)
        let displays = content.displays.filter { pending.remove($0.displayID) != nil }
        return await snapshots(for: displays, excludingWindows: excluded)
    }

    /// Captures every attached display.
    public func captureAllDisplays() async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return await snapshots(
            for: content.displays,
            excludingWindows: ownWindows(in: content)
        )
    }

    // MARK: - Private

    /// Captures each display, skipping the ones that fail.
    ///
    /// A display that drops out between enumeration and capture (unplugged
    /// mid-call) must not fail the whole batch, so it is simply absent from
    /// the result.
    private func snapshots(
        for displays: [SCDisplay],
        excludingWindows excluded: [SCWindow]
    ) async -> [DisplaySnapshot] {
        var snapshots = [DisplaySnapshot]()
        snapshots.reserveCapacity(displays.count)
        for display in displays {
            guard let snapshot = try? await capture(display, excludingWindows: excluded) else { continue }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    /// Captures a single display.
    ///
    /// The screens are captured *without* this app's own windows: Overmark
    /// composites its annotations on top of the raw capture itself, so the
    /// overlay panels (which are visible on screen at that moment) must not
    /// land in the image too — that would double-draw every stroke and bake
    /// the floating toolbar into exported screenshots.
    private func capture(
        _ display: SCDisplay,
        excludingWindows excluded: [SCWindow]
    ) async throws -> DisplaySnapshot {
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let info = Self.describe(display)

        let configuration = SCStreamConfiguration()
        configuration.width = info.pixelWidth
        configuration.height = info.pixelHeight
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        return DisplaySnapshot(
            image: image,
            screen: info.screen,
            displayID: display.displayID
        )
    }

    /// The windows that belong to this app.
    private func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        return content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID
        }
    }

    /// Derives the geometry of a ScreenCaptureKit display.
    ///
    /// The matching `NSScreen` is found by native display id, not by frame:
    /// `SCDisplay.frame` and `NSScreen.frame` are not guaranteed to share a
    /// coordinate space, and a frame comparison silently falls back to a
    /// scale of 1 on the wrong match, which would capture non-Retina
    /// resolution. The matched screen supplies the AppKit-space frame the
    /// rest of the app reasons in, plus the backing scale factor.
    ///
    /// Public because the recorder (`OvermarkRecorder`) computes its
    /// stream geometry through the same helper, so screenshots and captures
    /// never drift apart.
    public nonisolated static func geometry(for display: SCDisplay) -> DisplayInfo {
        describe(display)
    }

    private static func describe(_ display: SCDisplay) -> DisplayInfo {
        let screen = NSScreen.screens.first { candidate in
            (candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == display.displayID
        }

        let frame = screen?.frame ?? display.frame
        let origin = Point(x: Double(frame.origin.x), y: Double(frame.origin.y))
        let size = Size(width: Double(frame.width), height: Double(frame.height))
        let scale = screen?.backingScaleFactor ?? 1

        return DisplayInfo(
            displayID: display.displayID,
            screen: ScreenFrame(origin: origin, size: size, scale: scale),
            pixelWidth: Int(Double(size.width) * scale),
            pixelHeight: Int(Double(size.height) * scale)
        )
    }
}

