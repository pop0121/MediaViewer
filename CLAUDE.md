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

The `MediaViewerTests` target covers the grouping/collapse matrix and the vivo album importer.

## High-Level Architecture

### Entry Point and UI

`MediaViewerApp.swift` creates a `WindowGroup` with a single `GalleryView`. `GalleryView` owns a `LibraryViewModel` and switches between a folder picker (`RootSelectorView`) and the media grid.

### State and Data Flow

`LibraryViewModel` is the central `@MainActor` observable object. It:

- Loads the previously chosen root folder from `BookmarkStore` on launch.
- Creates a `PersistenceController` whose SQLite store lives inside a hidden `.mediaviewer/Store/` directory under the chosen root.
- Runs `MediaScanner` to reconcile the filesystem with the Core Data index, reporting enumerating/indexing/saving progress and honouring task cancellation.
- Fetches items in batches of 1,000 from Core Data into lightweight `MediaItem` structs as soon as the index is ready; thumbnail cleanup and reverse geocoding run afterwards in a cancellable maintenance task.
- Groups items reactively based on `groupingMode` and `zoomLevel`; date keys are computed once per item and cached so zoom/collapse/paging only re-bucket.

### Filesystem Access

The app relies on security-scoped bookmarks. `BookmarkStore` saves/loads the bookmark for the root folder in `UserDefaults`. Most file access is wrapped in `URL.withSecurityScope`. Security-scoped bookmarks are bound to the creating binary's signing identity, so `BookmarkStore` falls back to `.withoutUI` resolution when scoped resolution fails — dev builds run via `swift run` resolve bookmarks created by the bundled `.app` (and vice versa) this way; inside the sandbox both fail and the user re-picks the folder.

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
5. Returns the number of processed and actually removed entries; thumbnail cleanup happens outside the scan.

`scan(rootURL:progress:)` takes a `@Sendable (ScanProgress)` callback (phases: enumerating, indexing, saving) and checks `Task.checkCancellation()` between enumeration and metadata chunks.

`MetadataExtractor` uses ImageIO/EXIF for photos and AVFoundation for videos. Video location metadata is parsed from QuickTime ISO 6709 strings.

### Thumbnails

`ThumbnailGenerator` serves two tiers: `.grid` (320px, prefers the embedded EXIF thumbnail) and `.fullscreen` (1024px placeholder). Each tier has its own `NSCache` (256MB grid ≈ 850 images, 128MB fullscreen ≈ 42) and its own JPEG on disk, keyed by relative path, modification date and tier. Decoding happens inside the generator with `kCGImageSourceShouldCacheImmediately`, so callers only bind already-decoded images.

Concurrent requests for the same path are coalesced into one detached task; a cancelled caller does not cancel that shared work. Photos use `CGImageSourceCreateThumbnailAtIndex`; videos use `AVAssetImageGenerator` at the midpoint.

### Geocoding

`GeocoderService` reverse-geocodes unique coordinates with `CLGeocoder`, throttled to one request per second. It falls back to `AmapGeocoderService` for network failures or regions where Apple's geocoder is unreliable. Results are cached in `LocationNameEntity`. Failed coordinates are marked "Unknown Location" to avoid retry loops.

### Viewer

`FullscreenViewerView` overlays the grid and supports arrow-key navigation, Escape to close, and Space to play/pause video. Key events are handled synchronously on the main actor. Photos show the 1024px placeholder immediately while the full-resolution image is decoded off the main thread with ImageIO (EXIF orientation applied); ±2 neighbour placeholders are prefetched. Videos use `VideoPlayerView` (an `NSViewRepresentable` wrapping `AVPlayerView`), autoplay with audio enabled, and replace their `AVPlayerItem` when the selected media changes.

`GalleryView` uses `LazyVGrid` with pinned section headers; the viewer opens/closes with a combined opacity/scale transition.

### Albums

`MediaItem.albumNames` combines two sources:

- **Folder albums**: the item's parent directory relative to the library root, derived at read time from `relativePath` and never stored.
- **vivo-imported albums**: `VivoAlbumImporter` reads vivo 办公套件 (pcsuite)'s transfer log `~/Library/Application Support/pcsuite/database/TransferRecord.db` (opened read-only via SQLite3 with `immutable=1`), matches `savePath` against the indexed files, and stores the album (parent directory of the phone-side `phonePath`) as JSON in the optional `albumNamesRaw` column on `MediaItemEntity`. The importer owns that column wholesale and is idempotent. It runs automatically after each scan and from the sidebar button; sandboxed builds can be granted access via a security-scoped bookmark to `TransferRecord.db`. Only files transferred through the suite have records; a flattened export leaves nothing to recover.

The gallery is a `NavigationSplitView`: `AlbumSidebarView` lists albums (name + loaded count, sorted by count) and filters the grid/map via `LibraryViewModel.selectedAlbum`, independent of the date/location grouping mode.

### Observability

Diagnostics use `os.Logger` categories under subsystem `com.example.MediaViewer` (`Log`). `Perf` always emits Instruments signposts; set `MEDIAVIEWER_TIMING=1` to also log readable durations.

## Distribution Notes

The repository includes `Resources/Info.plist` and `Resources/MediaViewer.entitlements` for wrapping the SPM package into an `.app` bundle. The entitlements enable app sandbox, user-selected read-only file access, and outbound network access (for geocoding).
