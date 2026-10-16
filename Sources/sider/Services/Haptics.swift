import AppKit

/// Trackpad feedback, so the panel can be felt as well as seen. Silent, local to the pad and
/// free; a no-op on a trackpad with no Taptic Engine and when the user turned it off.
enum Haptics {
    /// A discrete state change: the panel opening.
    static func levelChange() {
        perform(.levelChange)
    }

    /// A detent: the selection landing on another card.
    static func alignment() {
        perform(.alignment)
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Preferences.shared.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
