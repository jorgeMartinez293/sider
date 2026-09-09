/// Where each card goes when the strip grows out from the middle of the screen.
///
/// The most recently put-away window sits at the vertical centre and the rest alternate
/// around it, so the card you just made is always in the same place — at eye level, next to
/// where the pointer already is — however many there are. A plain top-down list moves every
/// card down by one each time you minimize something, which means the thing you are most
/// likely to want back is never twice in the same spot.
///
/// Pure and index-based so the ordering can be tested without a window, a screen or a view.
enum CenteredStackLayout {

    /// Recency indices (0 = most recent) in the order they should be drawn, top to bottom.
    ///
    /// For five windows: `[4, 2, 0, 1, 3]` — 0 in the middle, odd indices below it, even ones
    /// above, each pair stepping one further out.
    static func order(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var above: [Int] = []
        var below: [Int] = []
        for index in 0..<count {
            // 0 anchors the centre; from there odd indices go below and even ones above, so
            // the strip stays balanced as it grows.
            if index != 0, index.isMultiple(of: 2) {
                above.append(index)
            } else {
                below.append(index)
            }
        }
        return above.reversed() + below
    }
}
