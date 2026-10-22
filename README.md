# Presentify

An annotation app for macOS. It draws on top of whatever you are presenting —
freehand strokes, arrows, shapes, numbered steps — and can add a cursor effect
so the audience follows your pointer.

It lives in the menu bar, not the Dock.

## Requirements

- macOS 14 or later
- Xcode 16 or later (for the Swift toolchain)

## Building

```bash
swift build -c release
```

## Building the app bundle

The permissions on macOS (Screen Recording and Accessibility) are keyed on the
**bundle identifier**, not on the process. A bare executable can never appear
in "Privacy & Security", so the app has to be a real `.app` bundle to be
granted them.

```bash
Scripts/build-app.sh
```

This produces:

- `build/Presentify.app` — the application bundle
- `build/Presentify.dmg` — a disk image with a drag-and-drop install

The script builds the release binary, assembles the bundle from
`Support/Info.plist`, draws the icon, signs the result and packages the DMG.
Everything is reproducible: re-run it at any time.

### Signing

Without an identity the app is signed **ad-hoc**. That is enough to run it
locally, but macOS will still ask you to confirm an unidentified developer the
first time you open it, and Gatekeeper rejects it when it arrives from
elsewhere.

To sign properly you need a *Developer ID Application* certificate from a
paid Apple Developer account:

```bash
Scripts/build-app.sh --sign "Developer ID Application: YOUR NAME (TEAMID)"
```

or via the environment:

```bash
PRESENTIFY_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
    Scripts/build-app.sh
```

To check what identities are available:

```bash
security find-identity -v -p codesigning
```

## Granting the permissions

Presentify needs two permissions up front, plus an optional third one for
recording with sound. All of which macOS grants per app:

| Permission | Why |
| --- | --- |
| **Screen Recording** | Reads the screen so annotations can be drawn on top of it, and records/captures it. |
| **Accessibility** | Tracks the pointer globally and observes global hotkeys while another app is frontmost. |
| **Microphone** *(optional)* | Records your voice into a presentation video when "Record the microphone" is on. Asked only the first time the toggle is used. |

On first launch the app shows an onboarding window that explains the two
required ones and links straight to the right System Settings pane. If you
skipped it, open **Presentify → Permissions** from the menu bar.

To grant them manually:

1. Open **System Settings → Privacy & Security → Screen Recording**
2. Turn on **Presentify**
3. Open **System Settings → Privacy & Security → Accessibility**
4. Turn on **Presentify**
5. **Quit and reopen** Presentify — macOS caches the permission state

> Granting these to the app means the permissions survive reinstalling and are
> never inherited by the terminal you happen to be using.

## Recording a presentation

Start annotating (⌘⇧A), then hit the red record button in the control bar
or press **⌘⇧R**:

| | |
| --- | --- |
| Output | One `.mov` per session — "Presentify 2026-10-22 10-30-00.mov" — in `~/Movies/Presentify` (folder changeable in **Presentify → General**). |
| Encoding | H.264 or HEVC, 30 or 60 fps — **Presentify → General → Recording**. |
| Microphone | Off by default; the toggle in **General → Recording** asks for the permission the first time. If access is off, Presentify records without sound and says so. |
| Target | **Presentify → General → Recording target** — the whole display or one window. |
| What ends up on tape | Display mode: the whole chosen display — annotations, cursor effects and everything else on that screen (Presentify's own chrome is excluded). Window mode: just that window, with your annotations drawn into the video as it records. |
| Which screen | **Presentify → General → Recording screen** — the main display or any attached screen by name. |

Ending the session (ESC, "Done" or quitting Presentify) always finalizes the
file — a recording is never left half-written. If the recording screen could
not deliver frames (or the run came out empty), the menu-bar app tells you
instead of silently succeeding.

In window mode the video track is sized when recording starts: resizing the
window afterwards letterboxes the picture instead of changing the video's
dimensions, and dedicated cursor effects (spotlight, blur, laser) are not
baked into the frame — annotations are.

## Troubleshooting

**"Presentify" does not appear in the Screen Recording list.**
The app has to be launched from the bundle at least once
(`open build/Presentify.app`) so that macOS registers it. Add it with the `+`
button if needed.

**The pointer effect does not follow the cursor.**
The Accessibility permission is missing. Grant it in System Settings, then
switch back to Presentify: the app re-reads the permission when it becomes
active, so no restart is needed.

**A permission that was granted before is suddenly "not set up" again.**
The permissions are keyed on the app's *designated requirement*, not on the
bundle identifier alone. An ad-hoc signature gets `cdhash <hash>` as its
requirement, and that hash changes on every rebuild — so the rebuilt app no
longer matches the row macOS stored for the old build, and the permission
reads as missing.

The build script avoids this by pinning the requirement to the bundle
identifier (`designated => identifier "com.presentify.app"`), which is stable
across rebuilds. A Developer ID signature is already stable and needs no
extra handling.

If a build predates that change, the stored rows still point at the old
cdhash and have to be dropped once:

```bash
tccutil reset Accessibility com.presentify.app
tccutil reset ScreenCapture com.presentify.app
```

Then grant both permissions again in System Settings. From then on they
survive every rebuild.

**The screen capture is black.**
Screen Recording was granted while the app was already running. Restart
Presentify after granting it.

**macOS says the app is damaged or from an unidentified developer.**
The app is ad-hoc signed. Use a Developer ID certificate, or right-click the
app in Finder and choose **Open** to bypass the one-time check.

## Layout

```
Support/Info.plist            Bundle metadata, including the bundle identifier
Support/Presentify.entitlements  Hardened runtime entitlements
Scripts/build-app.sh          Builds the bundle and the DMG
Scripts/make-icon.swift       Renders the app icon
Sources/PresentifyCore/       Geometry, annotations, permissions, app state
Sources/PresentifyCapture/    Screen capture via ScreenCaptureKit
Sources/PresentifyCursor/     Global pointer tracking and cursor effects
Sources/PresentifyOverlay/    The annotation canvas and its windows
Sources/PresentifyHotkeys/    Global hotkey registration
Sources/PresentifyRecorder/   The presentation recorder: SCStream (display or window) + microphone → MOV
Sources/PresentifyApp/        The SwiftUI app, menu bar and onboarding
```

`PresentifyCore` holds the model and has no UI or side effects, which is what
makes the rest testable.
