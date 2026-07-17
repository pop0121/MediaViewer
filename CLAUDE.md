# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MediaViewer is a native macOS app written in SwiftUI/AppKit. It browses photos and videos in a user-selected root folder, indexes metadata in Core Data, caches thumbnails on disk, and groups the grid by date or location.

- Swift tools version: 5.10
- Minimum platform: macOS 13
- Project type: Swift Package Manager executable (`Package.swift`)
- Supported media: `.jpg`, `.jpeg`, `.mp4`, `.mov`

## Common Commands

Build:

```bash
swift build
```

Run from the command line:

```bash
swift run MediaViewer
```

Open in Xcode:

```bash
open Package.swift
```

Run tests:

```bash
swift test
```

> Currently no test target exists; `swift test` reports "no tests found". The `Package.swift` has a single executable target.

## High-Level Architecture

### Entry Point and UI

`MediaViewerApp.swift` creates a `WindowGroup` with a single `GalleryView`. `GalleryView` owns a `LibraryViewModel` and switches between a folder picker (`RootSelectorView`) and the media grid.

### State and Data Flow

`LibraryViewModel` is the central `@MainActor` observable object. It:

- Loads the previously chosen root folder from `BookmarkStore` on launch.
- Creates a `PersistenceController` whose SQLite store lives inside a hidden `.mediaviewer/Store/` directory under the chosen root.
- Runs `MediaScanner` to reconcile the filesystem with the Core Data index.
- Fetches items in batches of 1,000 from Core Data into lightweight `MediaItem` structs.
- Groups items reactively based on `groupingMode` and `zoomLevel`.

### Filesystem Access

The app relies on security-scoped bookmarks. `BookmarkStore` saves/loads the bookmark for the root folder in `UserDefaults`. Most file access is wrapped in `URL.withSecurityScope`.

### Persistence

The Core Data model is built in code in `PersistenceController.makeModel()`; there is no `.xcdatamodeld` bundle. Entities:

- `MediaItemEntity`: indexed file metadata (path, dates, size, coordinate, location name, media type, thumbnail path).
- `LocationNameEntity`: reverse-geocoding cache keyed by coordinate.

The SQLite store and JPEG thumbnails are stored under `<root>/.mediaviewer/Store/` and `<root>/.mediaviewer/Thumbnails/`.

### Scanning and Metadata

`MediaScanner`:

1. Recursively enumerates the root folder, skipping the `.mediaviewer` and `.database` directories.
2. Compares each file's modification date against the Core Data index to find new/changed files.
3. Extracts metadata concurrently (bounded to 8 tasks) via `MetadataExtractor`.
4. Applies updates and deletes stale index entries in one background context save.
5. Triggers thumbnail generation for changed files and purges orphaned thumbnails.

`MetadataExtractor` uses ImageIO/EXIF for photos and AVFoundation for videos. Video location metadata is parsed from QuickTime ISO 6709 strings.

### Thumbnails

`ThumbnailGenerator` keeps an in-memory `NSCache` capped at 200 images/200 MB and writes JPEG thumbnails to disk using a stable hash of relative path and modification date. Photos use `CGImageSourceCreateThumbnailAtIndex`; videos use `AVAssetImageGenerator` at the midpoint.

### Geocoding

`GeocoderService` reverse-geocodes unique coordinates with `CLGeocoder`, throttled to one request per second. It falls back to `AmapGeocoderService` for network failures or regions where Apple's geocoder is unreliable. Results are cached in `LocationNameEntity`. Failed coordinates are marked "Unknown Location" to avoid retry loops.

### Viewer

`FullscreenViewerView` overlays the grid and supports arrow-key navigation, Escape to close, and Space to play/pause video. Photos load full-size `NSImage` and support pinch zoom and drag pan; videos use `VideoPlayerView` (an `NSViewRepresentable` wrapping `AVPlayerView`) and autoplay muted.

## Distribution Notes

The repository includes `Resources/Info.plist` and `Resources/MediaViewer.entitlements` for wrapping the SPM package into an `.app` bundle. The entitlements enable app sandbox, user-selected read-only file access, and outbound network access (for geocoding).
