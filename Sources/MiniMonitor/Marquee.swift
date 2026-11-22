import AppKit

/// One line of text scrolling right to left through its bounds as a seamless loop
/// (a second copy follows the first); centred and still when it fits.
///
/// The text is drawn whole into one layer's contents and Core Animation slides that
/// layer, so the scroll costs nothing per frame here. (A text field won't do: AppKit
/// only draws the part of it inside the clipping bounds, so the rest scrolls in blank.)
final class MarqueeView: NSView {
    private let strip = CALayer()
    private let font = NSFont.systemFont(ofSize: 12)
    private let speed: CGFloat = 20  // points per second
    private let gap: CGFloat = 16  // between the end of the name and its next copy
    private var text = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(strip)
    }

    required init?(coder: NSCoder) { nil }

    // Clicks go through to the status item's button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        restart()
    }

    func clear() {
        strip.removeAllAnimations()
        strip.contents = nil
        text = ""
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { restart() }
    }

    // Light/dark menu bar, and moving to a display of another scale.
    override func viewDidChangeEffectiveAppearance() { restart() }
    override func viewDidChangeBackingProperties() { restart() }

    private func restart() {
        guard !text.isEmpty else { return }
        strip.removeAllAnimations()

        var color = NSColor.white
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .white
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let name = text as NSString
        let size = name.size(withAttributes: attributes)
        let width = ceil(size.width)
        let height = ceil(size.height)
        let scrolls = width > bounds.width
        let period = width + gap  // one cycle moves exactly one copy: no seam
        let stripWidth = scrolls ? period + width : width

        let image = NSImage(size: NSSize(width: stripWidth, height: height), flipped: false) { _ in
            name.draw(at: .zero, withAttributes: attributes)
            if scrolls { name.draw(at: NSPoint(x: period, y: 0), withAttributes: attributes) }
            return true
        }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.contentsScale = scale
        strip.contents = image.layerContents(forContentsScale: scale)
        // Starts with the name's beginning in view.
        strip.frame = CGRect(
            x: scrolls ? 0 : ((bounds.width - width) / 2).rounded(),
            y: ((bounds.height - height) / 2).rounded(), width: stripWidth, height: height)
        CATransaction.commit()

        guard scrolls else { return }
        let scroll = CABasicAnimation(keyPath: "transform.translation.x")
        scroll.fromValue = 0
        scroll.toValue = -period
        scroll.duration = period / speed
        scroll.repeatCount = .infinity
        strip.add(scroll, forKey: "scroll")
    }
}
