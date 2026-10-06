import AppKit
import QuartzCore

/// Connects the trackpad to `FourFingerGesture` and `FiveFingerTap` and reports what they
/// decided.
///
/// Owns no UI. The caller says how many cards there are and which one the highlight starts
/// on, and is told when to open the panel, which card is highlighted, and when to commit or
/// give up.
final class FourFingerSwitcher {

    /// Open the panel.
    var onBegan: (() -> Void)?
    /// The highlight moved to this card, or off all of them.
    var onSelected: ((Int?) -> Void)?
    /// The fingers lifted. The index is the highlighted card, if there was one.
    var onEnded: ((Int?) -> Void)?
    /// The gesture was abandoned; put the panel away without choosing anything.
    var onCancelled: (() -> Void)?

    /// The whole hand tapped the pad.
    var onFiveFingerTap: (() -> Void)?

    /// How many cards the strip has, asked fresh on every frame — windows come and go while
    /// the gesture is running.
    var itemCount: () -> Int = { 0 }
    /// The card the highlight lands on first.
    var startIndex: () -> Int = { 0 }

    /// True from the moment the panel is opened until the gesture is over. The hover monitor
    /// reads it so the pointer being nowhere near the panel does not close it underneath the
    /// fingers.
    var isActive: Bool { gesture.isActive }

    private var gesture = FourFingerGesture()
    private var tap = FiveFingerTap()
    private var switchEnabled = false
    private var tapEnabled = false
    /// The trackpad that started the gesture. With a built-in pad and a Magic Trackpad both
    /// attached, frames from the other one would otherwise be read as the same hand.
    private var device: Int?
    private var watchdog: Timer?
    /// Stops Mission Control and App Exposé from answering the same four fingers.
    private let systemSwipes = SystemSwipeBlocker()

    init() {
        // Either test alone has a gap. The live count is ahead of the gesture by one hop to
        // the main queue, so it covers a swipe that starts the instant the fingers land; the
        // gesture covers a hand that has since dropped to three fingers but is still ours.
        systemSwipes.shouldBlock = { [weak self] in
            MultitouchBridge.shared.fingersDown >= FourFingerGesture.fingersRequired
                || self?.gesture.isEngaged == true
        }
    }

    /// - Parameters:
    ///   - switching: Four fingers open the panel and pick a window.
    ///   - tapping: A five-finger tap is reported.
    func apply(switching: Bool, tapping: Bool) {
        tapEnabled = tapping
        if !tapping { tap = FiveFingerTap() }

        if switching || tapping {
            MultitouchBridge.shared.onFrame = { [weak self] in self?.handle($0) }
            MultitouchBridge.shared.start()
        } else {
            MultitouchBridge.shared.stop()
            MultitouchBridge.shared.onFrame = nil
        }

        switchEnabled = switching
        if switching {
            systemSwipes.start()
        } else {
            systemSwipes.stop()
            if gesture.isActive { onCancelled?() }
            gesture = FourFingerGesture()
            device = nil
            stopWatchdog()
        }
    }

    private func handle(_ frame: MultitouchBridge.Frame) {
        let now = CACurrentMediaTime()

        if tapEnabled, tap.update(fingers: frame.fingers, centroid: frame.centroid, time: now) {
            Logger.log("five-finger tap")
            onFiveFingerTap?()
        }

        guard switchEnabled else { return }
        if let device, device != frame.device { return }

        let events = gesture.update(fingers: frame.fingers,
                                    centroid: frame.centroid,
                                    time: now,
                                    itemCount: itemCount(),
                                    startIndex: startIndex(),
                                    holdOff: tapEnabled && tap.isCandidate)
        dispatch(events)
        updateEngagement(from: frame)
    }

    private func dispatch(_ events: [FourFingerGesture.Event]) {
        for event in events {
            Logger.log("four-finger gesture: \(event)")
            switch event {
            case .began:           onBegan?()
            case .selected(let i): onSelected?(i)
            case .ended(let i):    onEnded?(i)
            case .cancelled:       onCancelled?()
            }
        }
    }

    /// Settles what follows an update: which trackpad is ours, and whether the watchdog needs
    /// to be running.
    private func updateEngagement(from frame: MultitouchBridge.Frame) {
        if gesture.isEngaged {
            device = device ?? frame.device
            startWatchdog()
        } else {
            device = nil
            stopWatchdog()
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        // Fast enough that a release decided here, rather than by a frame, is not felt as lag.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dispatch(self.gesture.tick(time: CACurrentMediaTime()))
            if !self.gesture.isEngaged { self.device = nil; self.stopWatchdog() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }
}
