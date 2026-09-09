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

    /// A window is being dragged toward the edge and would be put away if released. Drives the
    /// drop-target overlay — without it the panel opening mid-drag looks like a glitch rather
    /// than an invitation.
    @Published var isDropTarget = false

    /// The card currently being dragged out of the panel. It is dimmed in the strip while a
    /// `DragProxyWindow` carries its picture under the pointer.
    @Published var dragging: String?
}
