import AppKit
import CoreGraphics
import Foundation
import PresentifyCore
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
        guard let display = try await findDisplay(id: displayID) else {
            return nil
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return try await capture(display, excludingWindows: ownWindows(in: content))
    }

    /// Captures every attached display.
    public func captureAllDisplays() async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let excluded = ownWindows(in: content)
        var snapshots: [DisplaySnapshot] = []

        for display in content.displays {
            guard let snapshot = try? await capture(display, excludingWindows: excluded) else { continue }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    // MARK: - Private

    /// Captures a single display.
    ///
    /// The screens are captured *without* this app's own windows: Presentify
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

    private func findDisplay(id: CGDirectDisplayID) async throws -> SCDisplay? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return content.displays.first { $0.displayID == id }
    }

    /// Derives the geometry of a ScreenCaptureKit display.
    ///
    /// The matching `NSScreen` is found by native display id, not by frame:
    /// `SCDisplay.frame` and `NSScreen.frame` are not guaranteed to share a
    /// coordinate space, and a frame comparison silently falls back to a
    /// scale of 1 on the wrong match, which would capture non-Retina
    /// resolution. The matched screen supplies the AppKit-space frame the
    /// rest of the app reasons in, plus the backing scale factor.
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

