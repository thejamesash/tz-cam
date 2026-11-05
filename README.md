# TZ Cam

A macOS virtual camera that puts your local time on your video, with its own background blur or replacement. Made for Teams, works with anything that accepts a camera.

```
real camera ─▶ TZ Cam.app ─────────────────────────────▶ TZ Cam (virtual camera) ─▶ Teams
               Vision person segmentation               CoreMediaIO camera extension
               blur / image background                  (shows a placeholder when the
               clock badge: "4:12 PM / Lisbon · Thu · UTC+0"   app isn't running)
```

## Requirements

- macOS 14+, Apple Silicon recommended
- Xcode 15+ and `brew install xcodegen`
- A paid Apple Developer account (system extensions must be signed)

## Build and install

```sh
cd tzcam
make install TEAM=YOUR_TEAM_ID   # find it at developer.apple.com › Membership
```

This generates the Xcode project, builds, copies the app to `/Applications` (required for system extensions), and launches it.

On first launch:
1. Allow camera access.
2. Approve the extension in **System Settings › General › Login Items & Extensions › Camera Extensions**.
3. In Teams: **Settings › Devices › Camera › TZ Cam**. Turn off Teams' background effects.

To work in Xcode instead, run `make open TEAM=…`. Running from Xcode still needs the app copied to `/Applications` before the extension will activate.

## How it behaves

- The real camera only runs while an app is reading TZ Cam (or while the settings window is open). The extension stops pulling frames when nobody is watching, and the app notices its queue stays full.
- Background edges: **Auto** starts on Vision's accurate model and falls back to balanced if it averages over 22 ms a frame on your Mac. The measured time shows under the preview. Masks are upsampled with the camera image as a guide (`CIEdgePreserveUpsampleFilter`) and lightly smoothed across frames to cut flicker.
- Closing the window keeps the app in the menu bar. Quit from there.
- Teams mirrors your self-view, so the clock looks backwards to you and reads correctly to everyone else. If you'd rather see it correctly, turn off "Mirror my video" in Teams.
- Settings live in `UserDefaults`. Background images are copied into `~/Library/Application Support/TZCam`.

## Uninstall

```sh
systemextensionsctl list                        # find the extension
rm -rf /Applications/TZCam.app                  # removing the app removes the extension
```

## Layout

| Path | What |
|---|---|
| `App/Engine.swift` | Capture → render → virtual camera, auto camera on/off |
| `App/FrameProcessor.swift` | Segmentation, background, compositing |
| `App/ClockOverlay.swift` | The time badge |
| `App/VirtualCameraSink.swift` | Writes frames into the extension (CoreMediaIO C API) |
| `CameraExtension/` | The virtual camera itself |
| `project.yml` | XcodeGen project definition |
