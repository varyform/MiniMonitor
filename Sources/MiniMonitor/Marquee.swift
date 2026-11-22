import AppKit
import os

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
    private var painted: (text: String, color: CGColor, scale: CGFloat, scrolls: Bool)?
    private var laidOut: (text: String, size: NSSize)?
    private let log = Logger(subsystem: "com.oleh.MiniMonitor", category: "marquee")

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
        paint()
        layOut()
    }

    func clear() {
        strip.removeAllAnimations()
        strip.contents = nil
        text = ""
        painted = nil
        laidOut = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        paint()
        layOut()
    }

    // The status bar re-sends these on every redraw of its button (every 2 s), so
    // they only repaint, and only when the colour or scale really changed: restarting
    // the scroll here made it jump back to the start every 2 seconds.
    override func viewDidChangeEffectiveAppearance() { paint() }
    override func viewDidChangeBackingProperties() { paint() }

    private var textWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    private var scrolls: Bool { textWidth > bounds.width }
    private var period: CGFloat { textWidth + gap }  // one cycle moves exactly one copy

    /// The strip's contents: the name, and its second copy when it scrolls. Swapping
    /// contents doesn't touch the running animation.
    private func paint() {
        guard !text.isEmpty else { return }
        var color = NSColor.white.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        let scale = window?.backingScaleFactor ?? 2
        let scrolls = self.scrolls
        if let painted, painted.text == text, painted.color == color, painted.scale == scale,
            painted.scrolls == scrolls, strip.contents != nil
        {
            return
        }
        painted = (text, color, scale, scrolls)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(cgColor: color) ?? .white,
        ]
        let name = text as NSString
        let width = textWidth
        let height = ceil(name.size(withAttributes: attributes).height)
        let period = self.period
        let image = NSImage(
            size: NSSize(width: scrolls ? period + width : width, height: height), flipped: false
        ) { _ in
            name.draw(at: .zero, withAttributes: attributes)
            if scrolls { name.draw(at: NSPoint(x: period, y: 0), withAttributes: attributes) }
            return true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.contentsScale = scale
        strip.contents = image.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }

    /// Places the strip and starts the scroll: only for a new name or a new size.
    private func layOut() {
        guard !text.isEmpty, laidOut?.text != text || laidOut?.size != bounds.size else { return }
        laidOut = (text, bounds.size)
        log.info("scroll \(self.text, privacy: .public) restarts")
        strip.removeAllAnimations()

        let width = textWidth
        let height = ceil((text as NSString).size(withAttributes: [.font: font]).height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Starts with the name's beginning in view.
        strip.frame = CGRect(
            x: scrolls ? 0 : ((bounds.width - width) / 2).rounded(),
            y: ((bounds.height - height) / 2).rounded(),
            width: scrolls ? period + width : width, height: height)
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
