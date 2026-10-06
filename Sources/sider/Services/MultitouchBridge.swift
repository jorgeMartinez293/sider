import AppKit
import os

/// Raw finger positions from every attached trackpad, through the private
/// `MultitouchSupport` framework.
///
/// There is no public way to see fingers resting on the trackpad outside your own view: the
/// `NSTouch` API only reports to a view that has the pointer over it, and every system-wide
/// gesture event (swipe, pinch, rotate) arrives *after* macOS has decided what it means — and
/// four-finger gestures are ones macOS has already claimed. This framework is what
/// BetterTouchTool, Jitouch and the like are built on. It needs no permission, but it is not
/// documented and not guaranteed, so everything here is looked up with `dlsym` at runtime: if
/// a future macOS moves it, the feature quietly switches itself off instead of the app
/// failing to launch.
///
/// The framework calls back on a thread of its own at the trackpad's scan rate (~100 Hz). Each
/// frame is boiled down to a finger count and a centroid and handed to the main queue, so
/// nothing outside this file ever sees that thread.
final class MultitouchBridge {

    static let shared = MultitouchBridge()

    /// One trackpad scan, reduced to what the gesture needs.
    struct Frame {
        /// Which trackpad. Identifies a device only for as long as it stays attached.
        let device: Int
        /// Fingers actually on the surface — not hovering above it, not leaving it.
        let fingers: Int
        /// Mean position of those fingers, 0…1, origin at the bottom left.
        let centroid: CGPoint
    }

    /// Called on the main queue for every frame that has fingers on it, and once more when
    /// the last finger leaves.
    var onFrame: ((Frame) -> Void)?

    /// Whether at least one trackpad is being read.
    private(set) var isRunning = false

    /// How many fingers are on the trackpad at this instant.
    ///
    /// Unlike `onFrame` this does not wait for the main queue: it is written by the
    /// framework's thread as each scan arrives. `SystemSwipeBlocker` needs that — it has to
    /// decide about an event macOS is delivering *now*, and a count that is one main-queue
    /// hop stale could still say "three" for a hand that has four down.
    var fingersDown: Int { Self.liveFingers.withLock { $0 } }

    private static let liveFingers = OSAllocatedUnfairLock(initialState: 0)

    // MARK: - Framework entry points

    /// Mirrors the framework's per-finger record. Only `state` and the normalised position
    /// are read; the rest is here so the stride matches the one the framework writes with.
    private struct Touch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var fingerID: Int32
        var handID: Int32
        var posX: Float
        var posY: Float
        var velX: Float
        var velY: Float
        var size: Float
        var pressure: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var absPosX: Float
        var absPosY: Float
        var absVelX: Float
        var absVelY: Float
        var unused1: Int32
        var unused2: Int32
        var density: Float
    }

    /// The touches arrive as a raw pointer: a Swift struct cannot appear in a C signature, so
    /// the buffer is bound to `Touch` by hand where it is read.
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                                 Int32, Double, Int32) -> Void
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias DeviceCall = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias DeviceOnly = @convention(c) (UnsafeMutableRawPointer) -> Void

    private struct API {
        let createList: CreateList
        let register: Register
        let unregister: Register
        let start: DeviceCall
        let stop: DeviceOnly
    }

    private lazy var api: API? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                               RTLD_NOW),
              let list = dlsym(lib, "MTDeviceCreateList"),
              let register = dlsym(lib, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(lib, "MTUnregisterContactFrameCallback"),
              let start = dlsym(lib, "MTDeviceStart"),
              let stop = dlsym(lib, "MTDeviceStop")
        else { return nil }
        return API(createList: unsafeBitCast(list, to: CreateList.self),
                   register: unsafeBitCast(register, to: Register.self),
                   unregister: unsafeBitCast(unregister, to: Register.self),
                   start: unsafeBitCast(start, to: DeviceCall.self),
                   stop: unsafeBitCast(stop, to: DeviceOnly.self))
    }()

    /// Holds the devices the framework handed out. They live as long as this array does.
    private var devices: CFArray?
    private var rescanTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard rescanTimer == nil, let api else { return }
        attach(api)

        // Trackpads come and go (a Magic Trackpad switching on, a Bluetooth reconnect) and
        // every one of them stops reporting across sleep. Cheap to check, expensive to miss.
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.rescan()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The Bluetooth stack needs a moment to bring a wireless trackpad back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.restart() }
        }
    }

    func stop() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        detach()
    }

    private func restart() {
        guard rescanTimer != nil, let api else { return }
        detach()
        attach(api)
    }

    private func rescan() {
        guard let api, let list = api.createList()?.takeRetainedValue() else { return }
        let count = CFArrayGetCount(list)
        if count != (devices.map { CFArrayGetCount($0) } ?? 0) { restart() }
    }

    private func attach(_ api: API) {
        guard let list = api.createList()?.takeRetainedValue() else { return }
        devices = list
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            api.register(pointer, Self.contactFrame)
            api.start(pointer, 0)
        }
        isRunning = CFArrayGetCount(list) > 0
        if !isRunning { Logger.log("multitouch: no trackpad found") }
    }

    private func detach() {
        if let api, let devices {
            for index in 0..<CFArrayGetCount(devices) {
                guard let device = CFArrayGetValueAtIndex(devices, index) else { continue }
                let pointer = UnsafeMutableRawPointer(mutating: device)
                api.unregister(pointer, Self.contactFrame)
                api.stop(pointer)
            }
        }
        devices = nil
        isRunning = false
        Self.liveFingers.withLock { $0 = 0 }
    }

    // MARK: - Frames

    /// States 3 and 4 of the framework's 0–7 touch lifecycle: the finger has just made
    /// contact, and the finger is down. Everything below is a hover and everything above is
    /// the finger on its way off the glass.
    private static func isDown(_ state: Int32) -> Bool { state == 3 || state == 4 }

    /// Whether the previous frame forwarded was empty, so a stream of identical empty frames
    /// does not wake the main queue 100 times a second. Touched only by the framework's
    /// thread.
    private static var lastWasEmpty = true

    /// Runs on the framework's thread. A C function pointer cannot capture, so it reaches the
    /// bridge through `shared`.
    private static let contactFrame: Callback = { device, touches, count, _, _ in
        var fingers = 0
        var sumX: Float = 0
        var sumY: Float = 0

        if let touches, count > 0 {
            let buffer = UnsafeBufferPointer(start: touches.assumingMemoryBound(to: Touch.self),
                                             count: Int(count))
            // If the record is not the size this file thinks it is, every field after the
            // first is read from the wrong place. All the touches in one scan share a frame
            // number, so a mismatch means the layout changed: ignore the data rather than
            // act on garbage.
            guard buffer.allSatisfy({ $0.frame == buffer[0].frame && (0...7).contains($0.state) })
            else { return }
            for touch in buffer where isDown(touch.state) {
                fingers += 1
                sumX += touch.posX
                sumY += touch.posY
            }
        }

        liveFingers.withLock { [fingers] in $0 = fingers }

        if fingers == 0 {
            if lastWasEmpty { return }
            lastWasEmpty = true
        } else {
            lastWasEmpty = false
        }

        let frame = Frame(device: Int(bitPattern: device),
                          fingers: fingers,
                          centroid: fingers == 0
                            ? .zero
                            : CGPoint(x: CGFloat(sumX) / CGFloat(fingers),
                                      y: CGFloat(sumY) / CGFloat(fingers)))
        DispatchQueue.main.async { MultitouchBridge.shared.onFrame?(frame) }
    }
}
