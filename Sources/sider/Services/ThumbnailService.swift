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
    }

    private var cache: [CGWindowID: Entry] = [:]
    private let lock = NSLock()

    /// Enough for a very busy Mac; beyond this the oldest entries are dropped. Each entry is
    /// a downscaled bitmap (~600pt wide), so the ceiling is a few tens of MB.
    private let maxEntries = 80

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

        for window in content.windows where wanted.contains(window.windowID) {
            let config = SCStreamConfiguration()
            // Capture at roughly twice the widest card so the image is sharp on Retina and
            // still a fraction of a full-size window bitmap.
            let scale = min(1.0, 600.0 / max(window.frame.width, 1))
            config.width = max(Int(window.frame.width * scale), 1)
            config.height = max(Int(window.frame.height * scale), 1)
            config.showsCursor = false
            config.scalesToFit = true

            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let cgImage = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) else { continue }
            store(cgImage, for: window.windowID)
        }
        await MainActor.run { self.generation &+= 1 }
    }

    /// macOS 13 only. Deprecated in 14, and the reason the branch above exists.
    private func captureLegacy(_ id: CGWindowID) {
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, id, options),
              cgImage.width > 1, cgImage.height > 1 else { return }
        store(downscale(cgImage, maxWidth: 600), for: id)
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

    private func store(_ cgImage: CGImage, for id: CGWindowID) {
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height))
        lock.lock()
        cache[id] = Entry(image: image, captured: Date())
        if cache.count > maxEntries {
            let doomed = cache.sorted { $0.value.captured < $1.value.captured }
                .prefix(cache.count - maxEntries)
                .map(\.key)
            for key in doomed { cache.removeValue(forKey: key) }
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
