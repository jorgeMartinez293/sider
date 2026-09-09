import AppKit
import Combine
import CoreGraphics
import ScreenCaptureKit

/// Keeps a recent picture of every window, so a *minimized* window can still be shown.
///
/// This is the awkward truth the whole app is built around: **a minimized window cannot be
/// captured.** It has no backing surface on any display, so ScreenCaptureKit returns nothing
/// and `CGWindowListCreateImage` returns a blank. The Dock can show its genie-in thumbnail
/// only because the WindowServer kept the last frame for itself, and there is no API to ask
/// for it.
///
/// So sider captures windows *while they are still visible* and keeps the last frame. The
/// cadence is a compromise between freshness and cost:
///
///  * the frontmost window every few seconds — it is the one most likely to be minimized next,
///  * every visible window on a slow sweep, so a window you have not touched in a while still
///    has a reasonably current picture,
///  * an immediate capture of an app's windows the moment it stops being frontmost, which is
///    the single best predictor of "about to be put away".
///
/// Nothing is written to disk. The cache lives in memory and dies with the process.
final class ThumbnailService: ObservableObject {
    static let shared = ThumbnailService()

    /// Bumped whenever a capture lands. Views observe this rather than the dictionary so a
    /// refresh redraws the cards without the cache having to be `@Published` (which would
    /// copy it on every mutation).
    @Published private(set) var generation = 0

    private struct Entry {
        let image: NSImage
        let captured: Date
        /// Bitmap size, for the cache budget.
        let bytes: Int
    }

    private var cache: [CGWindowID: Entry] = [:]
    private let lock = NSLock()

    /// Cache ceiling, in bytes rather than entries.
    ///
    /// Counting entries was wrong once the captures got sharper: an entry is anywhere from
    /// 0.4 MB (a small window at the smallest card size) to 6 MB (a wide window at the
    /// largest), so a fixed count either wastes the budget or blows through it by 4×. This
    /// bounds what actually matters.
    private let maxCacheBytes = 96 * 1024 * 1024

    private var frontTimer: Timer?
    private var sweepTimer: Timer?
    private var started = false
    private let queue = DispatchQueue(label: "com.jorge.sider.capture", qos: .utility)

    /// Guards against a slow sweep overlapping the next one on a Mac with many windows.
    private var sweepInFlight = false

    private init() {}

    // MARK: - Permission

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time. A grant only takes effect for a process that
    /// launched after it, so `false` here does not mean refused — the UI keeps showing the
    /// permission state until `hasPermission` reads true.
    @discardableResult
    func requestPermission() -> Bool {
        UserDefaults.standard.set(true, forKey: "screenRecordingRequested")
        return CGRequestScreenCaptureAccess()
    }

    var wasEverRequested: Bool {
        UserDefaults.standard.bool(forKey: "screenRecordingRequested")
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDeactivated(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)

        let front = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in self?.captureFrontmost() }
        let sweep = Timer(timeInterval: 12.0, repeats: true) { [weak self] _ in self?.captureAllVisible() }
        RunLoop.main.add(front, forMode: .common)
        RunLoop.main.add(sweep, forMode: .common)
        frontTimer = front
        sweepTimer = sweep

        captureAllVisible()
    }

    // MARK: - Reading

    func image(for windowID: CGWindowID?) -> NSImage? {
        guard let windowID else { return nil }
        lock.lock(); defer { lock.unlock() }
        return cache[windowID]?.image
    }

    func age(of windowID: CGWindowID?) -> TimeInterval? {
        guard let windowID else { return nil }
        lock.lock(); defer { lock.unlock() }
        return cache[windowID].map { Date().timeIntervalSince($0.captured) }
    }

    // MARK: - Capture triggers

    /// The app that just lost focus is the one whose windows are most likely to be minimized
    /// next (⌘M usually follows ⌘Tab by a fraction of a second, but ⌘H and clicking away come
    /// first far more often). Capturing here is what makes the common case look live.
    @objc private func appDeactivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        captureWindows(ofPID: app.processIdentifier)
    }

    private func captureFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        captureWindows(ofPID: app.processIdentifier, limit: 1)
    }

    /// Called when the panel is about to open, so any window that is still on screen (which
    /// only happens in the "every window" scope) is current rather than up to 12s stale.
    func refreshVisible() { captureAllVisible() }

    private func captureWindows(ofPID pid: pid_t, limit: Int? = nil) {
        guard hasPermission else { return }
        var ids = onScreenWindowIDs().filter { $0.pid == pid }.map(\.id)
        if let limit { ids = Array(ids.prefix(limit)) }
        capture(ids)
    }

    private func captureAllVisible() {
        guard hasPermission, !sweepInFlight else { return }
        sweepInFlight = true
        let ids = onScreenWindowIDs().map(\.id)
        capture(ids) { [weak self] in self?.sweepInFlight = false }
    }

    /// On-screen, layer-0 (ordinary application) windows big enough to be real, newest first.
    /// `CGWindowListCopyWindowInfo` is the cheap way to get this — it is a single call into
    /// the WindowServer with no per-window IPC, unlike the Accessibility API.
    private func onScreenWindowIDs() -> [(id: CGWindowID, pid: pid_t)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width > 80, height > 80
            else { return nil }
            return (id, pid)
        }
    }

    private func capture(_ ids: [CGWindowID], completion: (() -> Void)? = nil) {
        guard !ids.isEmpty else { completion?(); return }
        if #available(macOS 14.0, *) {
            Task { [weak self] in
                await self?.captureWithScreenCaptureKit(ids)
                await MainActor.run { completion?() }
            }
        } else {
            queue.async { [weak self] in
                for id in ids { self?.captureLegacy(id) }
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    // MARK: - Capture backends

    /// ScreenCaptureKit is the supported path on macOS 14+. It matters beyond deprecation
    /// warnings: since macOS 15 an app that captures through the old CoreGraphics call gets
    /// the recurring "…has been recording your screen" reminder, while ScreenCaptureKit
    /// does not.
    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(_ ids: [CGWindowID]) async {
        let wanted = Set(ids)
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true) else { return }

        let scale = Self.displayScale
        for window in content.windows where wanted.contains(window.windowID) {
            let pixels = capturePixelSize(for: window.frame.size, scale: scale)
            let config = SCStreamConfiguration()
            config.width = pixels.width
            config.height = pixels.height
            config.showsCursor = false
            config.scalesToFit = true
            // Ask for the real thing rather than whatever is cheapest. `.automatic` is free
            // to hand back a downscaled frame, which is the difference between a legible
            // preview and a blurry one.
            config.captureResolution = .best
            // The window's drop shadow is a wide band of near-transparent grey around the
            // frame. Captured, it eats pixels out of the budget and leaves a dirty edge once
            // the card crops to fill.
            config.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let cgImage = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) else { continue }
            store(cgImage, for: window.windowID, scale: scale)
        }
        await MainActor.run { self.generation &+= 1 }
    }

    /// How many pixels wide and tall to capture a window of `size` points.
    ///
    /// This used to be `min(1, 600 / width)` applied to the window's **point** size, which
    /// conflated two different units: `SCStreamConfiguration.width` is in pixels, and
    /// `SCWindow.frame` is in points. On a 2× display a 1500pt window was therefore captured
    /// at 600px — a fifth of its real resolution — and the card, drawn at 200pt (400 backing
    /// pixels) and cropped to fill, had less detail than it could show. That is the blur.
    ///
    /// The budget is derived from what the card actually needs: its width, in real pixels,
    /// doubled. The doubling is not slack — cropping to fill throws away one axis entirely
    /// (a tall window keeps its width and loses its height, or the reverse), and the hovered
    /// card scales up on top of that.
    ///
    /// Never above the window's own native resolution: upsampling past it adds bytes and no
    /// detail.
    private func capturePixelSize(for size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let card = CGFloat(Preferences.shared.cardWidth)
        let budget = min(card * 2 * scale, 1600)
        let native = size.width * scale
        let width = max(min(budget, native), 1)
        let ratio = size.height / max(size.width, 1)
        return (Int(width.rounded()), max(Int((width * ratio).rounded()), 1))
    }

    /// The sharpest screen attached, since a window can be dragged to any of them and the
    /// cache is shared.
    private static var displayScale: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    /// macOS 13 only. Deprecated in 14, and the reason the branch above exists.
    private func captureLegacy(_ id: CGWindowID) {
        // .bestResolution, not .nominalResolution: nominal returns a 1× bitmap regardless of
        // the display, which on Retina is half the detail the card can show.
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, id, options),
              cgImage.width > 1, cgImage.height > 1 else { return }
        let scale = Self.displayScale
        let target = capturePixelSize(for: CGSize(width: CGFloat(cgImage.width) / scale,
                                                  height: CGFloat(cgImage.height) / scale),
                                      scale: scale)
        store(downscale(cgImage, maxWidth: CGFloat(target.width)), for: id, scale: scale)
        DispatchQueue.main.async { self.generation &+= 1 }
    }

    private func downscale(_ image: CGImage, maxWidth: CGFloat) -> CGImage {
        guard CGFloat(image.width) > maxWidth else { return image }
        let scale = maxWidth / CGFloat(image.width)
        let width = Int(maxWidth), height = max(Int(CGFloat(image.height) * scale), 1)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func store(_ cgImage: CGImage, for id: CGWindowID, scale: CGFloat) {
        // Size in POINTS, not pixels. An NSImage whose size equals its pixel count declares
        // itself a 1× image, and AppKit then treats a 2×-resolution capture as if that were
        // all the detail there is — the extra pixels are thrown away on the way to the screen
        // instead of being used for it.
        let points = NSSize(width: CGFloat(cgImage.width) / scale,
                            height: CGFloat(cgImage.height) / scale)
        let image = NSImage(cgImage: cgImage, size: points)
        let bytes = cgImage.height * cgImage.bytesPerRow

        lock.lock()
        cache[id] = Entry(image: image, captured: Date(), bytes: bytes)
        var total = cache.values.reduce(0) { $0 + $1.bytes }
        if total > maxCacheBytes {
            // Oldest first, until it fits. The freshest captures are the ones on screen.
            for key in cache.sorted(by: { $0.value.captured < $1.value.captured }).map(\.key) {
                guard total > maxCacheBytes, key != id else { continue }
                total -= cache.removeValue(forKey: key)?.bytes ?? 0
            }
        }
        lock.unlock()
    }

    /// Drops entries for windows that no longer exist, so closing a hundred windows over a
    /// long session does not keep their bitmaps alive until the cap evicts them.
    func prune(keeping live: Set<CGWindowID>) {
        lock.lock()
        cache = cache.filter { live.contains($0.key) }
        lock.unlock()
    }
}
