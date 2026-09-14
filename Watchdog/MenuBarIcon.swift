import AppKit

/// The menu bar glyph: a paw, badged with what Watchdog is currently up to.
///
/// Deliberately a template image — macOS tints it for light, dark and the highlighted-menu state,
/// which a coloured icon can't follow. That means the badge has to say what it means by *shape*,
/// so the badges are the three everyone already knows: a tick, an ellipsis, a cross.
enum MenuBarIcon {
    enum Status: Equatable {
        /// Nothing watched yet — no badge, nothing to report.
        case empty
        case allRunning
        /// Something is down and coming back: counting down, starting, or briefly missing.
        case working
        /// Something has been given up on. Outranks everything else.
        case gaveUp
        /// Every watched app is paused.
        case paused
    }

    /// Sizes are a fight for room: the whole thing is 18pt tall, so the badge can only be a few
    /// points across before it starts eating the paw. Kept adjustable because the only way to
    /// judge it is to render it at true size and look.
    struct Metrics {
        /// Wider than it looks like it needs to be: the extra width is what stops the badge
        /// overlapping the paw, and the knockout gap from biting a chunk out of it.
        var canvas = NSSize(width: 26, height: 18)
        var paw: CGFloat = 13
        var badge: CGFloat = 11
        /// How much clear space to leave around the badge so it doesn't merge into the paw.
        /// Applied as a larger copy of the badge glyph punched out underneath it.
        var gap: CGFloat = 1
        /// Black, not bold. A template badge has no colour to help it, so weight is the only thing
        /// separating "there is a tick here" from a grey smudge.
        var weight: NSFont.Weight = .black
        /// Disc badges (`checkmark.circle.fill`) were tried and are far too heavy — at a size where
        /// the disc reads, it swallows the paw it's meant to be annotating.
        var filled = false

        static let standard = Metrics()
    }

    static func image(for status: Status, metrics: Metrics = .standard) -> NSImage {
        let image = NSImage(size: metrics.canvas, flipped: false) { rect in
            // An unbadged paw gets the whole canvas to itself.
            let pawPoints = status == .empty ? metrics.paw + 3 : metrics.paw
            if let paw = symbol("pawprint.fill", size: pawPoints, weight: .regular) {
                let s = paw.size
                let x = status == .empty ? (rect.width - s.width) / 2 : 0
                // Centred vertically, always. Top-aligning it to clear the badge makes the whole
                // icon sit visibly high against everything else in the menu bar.
                paw.draw(in: NSRect(x: x, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }

            let badgePoints = metrics.badge + opticalAdjustment(for: status)
            guard let name = badgeSymbol(for: status, filled: metrics.filled),
                  let badge = symbol(name, size: badgePoints, weight: metrics.weight) else { return true }
            let s = badge.size
            let frame = NSRect(x: rect.maxX - s.width, y: 0, width: s.width, height: s.height)

            // Clear a gap so the badge doesn't merge into the paw — but shaped like the badge
            // itself, not a rectangle. A rectangular knockout reads as an opaque tile sitting on
            // top of the paw; a glyph-shaped one reads as the badge simply having an outline.
            if let halo = symbol(name, size: badgePoints + metrics.gap * 2, weight: metrics.weight) {
                let h = halo.size
                halo.draw(in: NSRect(x: frame.midX - h.width / 2, y: frame.midY - h.height / 2,
                                     width: h.width, height: h.height),
                          from: .zero, operation: .destinationOut, fraction: 1)
            }
            badge.draw(in: frame)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// One point size doesn't sit right across all four glyphs: the tick's long diagonal makes it
    /// read noticeably bigger than the cross or the dots at the same nominal size.
    private static func opticalAdjustment(for status: Status) -> CGFloat {
        switch status {
        case .allRunning: -1
        default: 0
        }
    }

    private static func badgeSymbol(for status: Status, filled: Bool) -> String? {
        let base: String? = switch status {
        case .empty: nil
        case .allRunning: "checkmark"
        case .working: "ellipsis"
        case .gaveUp: "xmark"
        case .paused: "pause"
        }
        guard let base else { return nil }
        return filled ? "\(base).circle.fill" : (status == .paused ? "pause.fill" : base)
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}
