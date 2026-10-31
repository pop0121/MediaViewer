import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal

enum VideoEnhancementChain: String, CaseIterable, Sendable {
    case full
    case sharpen
    case median

    var includesMedian: Bool { self == .full || self == .median }
    var includesSharpen: Bool { self == .full || self == .sharpen }

    var displayName: String {
        switch self {
        case .full: return "median + sharpen"
        case .sharpen: return "sharpen only"
        case .median: return "median only"
        }
    }
}

enum VideoEnhancementSettings {
    private static let lock = NSLock()
    private static var storedChain: VideoEnhancementChain = .full

    /// Chain used by the next compositor frame. The UI only enables/disables
    /// the effect; the batch-6 measurement chooses the heaviest safe chain.
    static var chain: VideoEnhancementChain {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedChain
        }
        set {
            lock.lock()
            storedChain = newValue
            lock.unlock()
        }
    }

    /// Low-strength detail recovery. Tuned on the batch-6 sample videos; the
    /// benchmark can change these without changing the compositor.
    static var sharpenRadius: Double = 1.2
    static var sharpenIntensity: Double = 0.35
}

/// Per-playback diagnostics used by the macmini/office benchmark harness and
/// available in debug logs. It records processing time only, not full player
/// display timing.
final class VideoEnhancementDiagnostics: @unchecked Sendable {
    struct Snapshot: Sendable {
        let frames: Int
        let totalMilliseconds: Double
        let p95Milliseconds: Double
        let maxMilliseconds: Double
        let elapsedSeconds: Double
    }

    private let lock = NSLock()
    private var durations: [Double] = []
    private var startedAt: CFAbsoluteTime?

    func reset() {
        lock.lock()
        durations.removeAll(keepingCapacity: true)
        startedAt = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    func record(milliseconds: Double) {
        lock.lock()
        if startedAt == nil { startedAt = CFAbsoluteTimeGetCurrent() }
        durations.append(milliseconds)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let values = durations
        let start = startedAt
        lock.unlock()
        let sorted = values.sorted()
        let index = sorted.isEmpty ? 0 : min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        return Snapshot(
            frames: values.count,
            totalMilliseconds: values.reduce(0, +),
            p95Milliseconds: sorted.isEmpty ? 0 : sorted[index],
            maxMilliseconds: sorted.last ?? 0,
            elapsedSeconds: start.map { CFAbsoluteTimeGetCurrent() - $0 } ?? 0
        )
    }
}

/// Custom AVVideoCompositing implementation. Core Image runs at the source
/// resolution (`renderScale = 1`); AVPlayerLayer is responsible for the final
/// display scaling.
final class VideoEnhancementCompositor: NSObject, AVVideoCompositing {
    static let diagnostics = VideoEnhancementDiagnostics()

    private let queue = DispatchQueue(label: "MediaViewer.VideoEnhancement", qos: .userInitiated)
    private let stateLock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false
    private let medianFilter = CIFilter(name: "CIMedianFilter")
    private let unsharpFilter = CIFilter(name: "CIUnsharpMask")
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let ciContext: CIContext

    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        }
        super.init()
    }

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    var supportsWideColorSourceFrames: Bool { false }
    var canConformColorOfSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        stateLock.lock()
        renderContext = newRenderContext
        stateLock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // Retain the compositor until this request has been finished. A weak
        // capture allowed the compositor to deallocate while requests were
        // still queued (the macmini stress run logged "unfinished
        // AVAsynchronousVideoCompositionRequest deallocated"), which can drop
        // or black out frames during a toggle/seek.
        queue.async {
            self.process(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
        queue.sync {
            stateLock.lock()
            cancelled = false
            stateLock.unlock()
        }
    }

    private func process(_ request: AVAsynchronousVideoCompositionRequest) {
        stateLock.lock()
        let context = renderContext
        let isCancelled = cancelled
        stateLock.unlock()
        guard !isCancelled else {
            request.finishCancelledRequest()
            return
        }
        guard let context,
              let trackID = request.sourceTrackIDs.first?.int32Value,
              let sourceBuffer = request.sourceFrame(byTrackID: trackID) else {
            request.finish(with: NSError(
                domain: "MediaViewer.VideoEnhancement",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing source frame or render context"]
            ))
            return
        }

        let started = CFAbsoluteTimeGetCurrent()
        var image = CIImage(cvPixelBuffer: sourceBuffer)

        // The built-in layer instruction transform carries the source's
        // preferred orientation (for example v01's 90° rotation).
        if var transform = transform(for: request), !transform.isIdentity {
            // AVFoundation's layer transform is expressed with a top-left
            // origin, while CIImage uses a bottom-left origin. For 90°/270°
            // source rotations that difference shows up as a 180° flip; rotate
            // around the render center to keep portrait videos upright.
            if abs(transform.b) > 0.5 || abs(transform.c) > 0.5 {
                let center = CGPoint(x: context.size.width / 2, y: context.size.height / 2)
                let flip = CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: .pi)
                    .translatedBy(x: -center.x, y: -center.y)
                transform = transform.concatenating(flip)
            }
            image = image.transformed(by: transform)
        }
        if !context.renderTransform.isIdentity {
            image = image.transformed(by: context.renderTransform)
        }
        let bounds = CGRect(origin: .zero, size: context.size)
        image = image.cropped(to: bounds)

        let chain = VideoEnhancementSettings.chain
        if chain.includesMedian, let filter = medianFilter {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                image = output.cropped(to: bounds)
            }
        }
        if chain.includesSharpen, let filter = unsharpFilter {
            // CIVisionDetailSharpen and CIHighPass are not present on macOS 14;
            // CIUnsharpMask is the built-in high-pass-style equivalent.
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(VideoEnhancementSettings.sharpenRadius, forKey: kCIInputRadiusKey)
            filter.setValue(VideoEnhancementSettings.sharpenIntensity, forKey: kCIInputIntensityKey)
            if let output = filter.outputImage {
                image = output.cropped(to: bounds)
            }
        }

        guard let destination = context.newPixelBuffer() else {
            request.finish(with: NSError(
                domain: "MediaViewer.VideoEnhancement",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate output pixel buffer"]
            ))
            return
        }
        ciContext.render(image, to: destination, bounds: bounds, colorSpace: colorSpace)
        VideoEnhancementCompositor.diagnostics.record(
            milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1000
        )
        request.finish(withComposedVideoFrame: destination)
    }

    private func transform(for request: AVAsynchronousVideoCompositionRequest) -> CGAffineTransform? {
        // AVFoundation supplies an immutable AVVideoCompositionInstruction to
        // the custom compositor during playback. Do not narrow this cast to
        // AVMutableVideoCompositionInstruction: that cast fails at playback
        // time (while image generators may still use a mutable instruction),
        // which leaves the source untransformed and crops portrait videos to
        // the render size. This is the batch-7 portrait regression.
        guard let instruction = request.videoCompositionInstruction as? AVVideoCompositionInstruction,
              let layer = instruction.layerInstructions.first else {
            return nil
        }
        var start = CGAffineTransform.identity
        var end = CGAffineTransform.identity
        var timeRange = CMTimeRange.zero
        guard layer.getTransformRamp(
            for: request.compositionTime,
            start: &start,
            end: &end,
            timeRange: &timeRange
        ) else {
            return nil
        }
        // `getTransformRamp` may return a static start/end pair. Interpolate
        // for ramp instructions so the compositor and AVPlayerLayer agree at
        // every composition time, not just at the start of the instruction.
        guard timeRange.duration.seconds > 0 else { return start }
        let elapsed = request.compositionTime.seconds - timeRange.start.seconds
        let progress = min(1, max(0, elapsed / timeRange.duration.seconds))
        return start.interpolated(to: end, progress: progress)
    }
}

private extension CGAffineTransform {
    func interpolated(to other: CGAffineTransform, progress: Double) -> CGAffineTransform {
        let t = CGFloat(progress)
        return CGAffineTransform(
            a: a + (other.a - a) * t,
            b: b + (other.b - b) * t,
            c: c + (other.c - c) * t,
            d: d + (other.d - d) * t,
            tx: tx + (other.tx - tx) * t,
            ty: ty + (other.ty - ty) * t
        )
    }
}

enum VideoEnhancementCompositionFactory {
    /// Attach only when enhancement is enabled. Off uses the item's native
    /// videoComposition (nil), preserving batch-5 playback exactly.
    static func make(for url: URL, chain: VideoEnhancementChain) -> AVMutableVideoComposition? {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableVideoComposition(propertiesOf: asset)
        guard !composition.instructions.isEmpty else { return nil }
        VideoEnhancementSettings.chain = chain
        composition.renderScale = 1.0
        composition.customVideoCompositorClass = VideoEnhancementCompositor.self
        return composition
    }
}
