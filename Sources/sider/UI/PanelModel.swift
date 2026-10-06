import SwiftUI

/// The little bit of state the panel's views share with the controller that owns the window.
///
/// `isOpen` is what drives the entrance and exit animations. It is deliberately separate from
/// "the NSWindow is on screen": the window is ordered in *before* `isOpen` flips to true and
/// ordered out *after* it flips back to false, so SwiftUI has real frames to animate between
/// instead of the content popping in at its final position.
final class PanelModel: ObservableObject {
    @Published var isOpen = false
    @Published var hovered: String?

    /// The card the four-finger gesture is currently on. Drawn exactly like a hovered card —
    /// squared up and lifted — but kept apart from `hovered`, which the pointer owns and
    /// clears whenever it leaves a card.
    @Published var selected: String?

    /// A window is being dragged toward the edge and would be put away if released. Drives the
    /// drop-target overlay — without it the panel opening mid-drag looks like a glitch rather
    /// than an invitation.
    @Published var isDropTarget = false

    /// The card currently being dragged out of the panel. It is dimmed in the strip while a
    /// `DragProxyWindow` carries its picture under the pointer.
    @Published var dragging: String?

    /// The parts of the panel that sit under the menu bar and the Dock. The panel is as tall
    /// as the display, so content at rest is kept inside these while a scrolling strip is
    /// free to run under them, all the way to the edge of the screen.
    @Published var topInset: CGFloat = 0
    @Published var bottomInset: CGFloat = 0
}
