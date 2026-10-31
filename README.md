# MediaViewer

A native macOS app for browsing photos and videos stored in a user-selected root folder.

## Features

- Choose a root folder on launch (stored with a security-scoped bookmark for relaunch).
- Recursively scans for `.jpg`, `.jpeg`, `.mp4`, and `.mov` files.
- Extracts creation date and GPS location metadata from EXIF and QuickTime metadata.
- Displays media in a zoomable grid with pinned date/location section headers.
- Groups items by date (year / month / day, adapting to zoom level) or by location.
- Shows determinate scan progress and allows cancelling; partial results are kept.
- Click an item to open a full-window overlay viewer with animated transitions.
- Navigate with arrow keys, close with `Esc`, toggle video play/pause with `Space`.
- Videos autoplay muted in the viewer; switching media replaces the player item.
- Grid and full-screen images are decoded off the main thread; the viewer shows a
  1024px placeholder while the full-resolution image decodes.
- Generates and caches tiered thumbnails (320px grid, 1024px full-screen) and a
  metadata index in a hidden `.mediaviewer/` folder under the root path.
- Media files are never modified.

## Requirements

- macOS 13+
- Xcode 15+ (or Swift 6 toolchain) to build

## Project Structure

This is a Swift Package Manager project:

```
.
├── Package.swift
├── README.md
└── Sources/MediaViewer/
    ├── MediaViewerApp.swift
    ├── Models/
    ├── Services/
    └── Views/
```

## Build and Run

Open the project in Xcode:

```bash
open Package.swift
```

Or build from the command line with a full Xcode installation:

```bash
swift build
swift run MediaViewer
```

> **Note:** This project was developed in an environment with only the macOS Command Line Tools installed, where `swift build` fails due to a linker issue in the SPM manifest API (`PackageDescription.Package.__allocating_init` symbol missing). This appears to be an environment-specific toolchain/SDK mismatch. Building with a full Xcode.app installation is expected to succeed.

## First Launch

1. Launch the app.
2. Click **Choose Folder…** and select your media root, for example:
   `/Volumes/Lexar/vivo X100s Pro+732bfe`
3. The app creates a hidden `.mediaviewer/` folder under the root for the Core Data index and thumbnails.
4. The grid fills as files are scanned and thumbnailed.

## Use

- Use the **Group By** segmented control to switch between no grouping, date grouping, and location grouping.
- Drag the zoom slider to change grid cell size. Date grouping adapts:
  - Zoom > 1.2 → by day
  - Zoom 0.7–1.2 → by month
  - Zoom < 0.7 → by year
- Click any thumbnail to open it in the full-window viewer.
- In the viewer:
  - `←` / `↑` → previous item
  - `→` / `↓` → next item
  - `Esc` → close viewer
  - `Space` → play/pause video
  - Pinch/trackpad zoom and drag to pan photos.

## Sandboxing / Entitlements

When wrapping this SPM package into an `.app` bundle for distribution, apply these entitlements:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
```

The app already creates and resolves security-scoped bookmarks for the chosen root folder.

## Debugging

All diagnostics go through `os.Logger` (subsystems `com.example.MediaViewer`).
Set `MEDIAVIEWER_TIMING=1` to also log wall-clock timings for scans, first-screen
fetch, maintenance and per-phase durations; Instruments always receives the
corresponding signposts.

```bash
log stream --predicate 'subsystem == "com.example.MediaViewer"'
MEDIAVIEWER_TIMING=1 swift run MediaViewer
```

## Known Limitations / TODO

- The app keeps all indexed `MediaItem` values in memory. Very large libraries (>100k items) may need paging or a fetched-results controller.
- The first screen appears after the index pass finishes; changes are not published incrementally during indexing.
- The grid always requests the 320px tier. At zoom levels that make cells larger than 160pt on Retina, images are upscaled.
- Full-resolution photos are decoded whole (up to ~84MB for a 22MP JPEG) on a background thread; the viewer shows the 1024px placeholder until decoded.
- Reverse geocoding is throttled by `CLGeocoder`; large batches may take time and are done in a background pass after scanning.
- Video location metadata parsing is best-effort for common QuickTime ISO 6709 strings.
- Only `.jpg`, `.jpeg`, `.mp4`, and `.mov` are indexed (no HEIC/PNG/Live Photo).
