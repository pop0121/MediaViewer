# MediaViewer

A native macOS app for browsing photos and videos stored in a user-selected root folder.

## Features

- Choose a root folder on launch (stored with a security-scoped bookmark for relaunch).
- Recursively scans for `.jpg`, `.jpeg`, `.mp4`, and `.mov` files.
- Extracts creation date and GPS location metadata from EXIF and QuickTime metadata.
- Displays media in a density-adjustable grid (0.5×–2.0×, AppStorage, ⌘−/⌘+)
  with pinned date section headers.
- Time grouping is explicit: All / Years / Months / Days (default Months);
  switching granularity lands on the viewport anchor without filtering the
  timeline, and the All / year / month breadcrumb follows scrolling.
- Places mode shows a MapKit map with clustered representative-photo cards;
  screen-space merging prevents pin overlap, and a cluster opens its own grid
  with a `‹ Map` return.
- Shows determinate scan progress and allows cancelling; partial results are kept.
- Click an item to open a full-window overlay viewer with animated transitions.
- Navigate with arrow keys, close with `Esc`, toggle video play/pause with `Space`.
- Videos autoplay with audio enabled in the viewer; switching media replaces the player item.
- Grid and full-screen images are decoded off the main thread; the viewer shows a
  1024px placeholder, then a 2000px screen-sized decode, and decodes the native
  resolution only when zoomed past 1.4×.
- Generates and caches tiered thumbnails (320px grid, 640px zoomed-out grid,
  1024px full-screen) and a metadata index in a hidden `.mediaviewer/` folder
  under the root path.
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

- Use the **All / Years / Months / Days / Places** segmented control to choose
  the time sections or the map. Date granularity never changes with zoom.
- Drag the thumbnail slider from **Small** (left) to **Large** (right); it only
  changes cell size (and therefore the 320/640px thumbnail tier).
- In Places, pinch/scroll the map to recluster locally; tap a numeric cluster
  to zoom in, tap a single photo to open it, or use **Show Grid in This Area**
  to filter the grid to the current map bounds. Photos without GPS are counted
  in the toolbar and omitted from the map.
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
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

The app already creates and resolves security-scoped bookmarks for the chosen root folder.

## Reverse Geocoding Configuration

Amap (Gaode) is preferred inside China and Nominatim (OpenStreetMap) elsewhere;
either backend falls back to the other on failure. No key is committed.

- `MEDIAVIEWER_AMAP_KEY` (or Info.plist `AmapAPIKey`): Amap key. Without it the
  Amap backend fails locally and Nominatim handles requests.
- `MEDIAVIEWER_NOMINATIM_CONTACT` (or Info.plist `NominatimContact`): contact
  string included in the Nominatim User-Agent. Nominatim requests are throttled
  to 1/s and results are cached.

Location names display the required “© OpenStreetMap contributors (ODbL)”
attribution; map tiles are provided by MapKit (no external key).

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
- The grid is published incrementally during indexing, but full-library scans still take longer on slow volumes.
- Places clusters the visible region locally to roughly 20–60 badges; a very sparse region can show fewer.
- Pinch-to-zoom inside the photo viewer does not reset between items (unchanged from earlier batches).
- The 2000px screen decode of a 22MP JPEG takes roughly 200–300ms on the test machine; the 1024px placeholder is visible immediately.
- 640px/1024px tiers are generated on demand, so browsing zoomed out over a large library costs extra disk space (about 75KB per 640px image).
- Reverse geocoding is throttled to 1 request/s and runs as a background, cancellable pass after scanning; failed lookups are retried on the next scan.
- Nominatim may be unreachable from some networks; configure an Amap key for reliable in-China geocoding.
- Video location metadata parsing is best-effort for common QuickTime ISO 6709 strings.
- Only `.jpg`, `.jpeg`, `.mp4`, and `.mov` are indexed (no HEIC/PNG/Live Photo).
