import AppKit

/// One line of text scrolling right to left through its bounds, on repeat; centred
/// and still when it fits. Core Animation runs the scroll in the render server, so
/// it costs nothing per frame here.
final class MarqueeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let speed: CGFloat = 20  // points per second

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12)
        label.wantsLayer = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    // Clicks go through to the status item's button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String) {
        guard text != label.stringValue else { return }
        label.stringValue = text
        label.sizeToFit()
        restart()
    }

    func clear() {
        label.layer?.removeAllAnimations()
        label.stringValue = ""
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { restart() }
    }

    private func restart() {
        guard let layer = label.layer, !label.stringValue.isEmpty else { return }
        layer.removeAllAnimations()
        let width = label.frame.width
        let y = ((bounds.height - label.frame.height) / 2).rounded()
        guard width > bounds.width else {
            label.setFrameOrigin(NSPoint(x: ((bounds.width - width) / 2).rounded(), y: y))
            return
        }
        label.setFrameOrigin(NSPoint(x: 0, y: y))
        let scroll = CABasicAnimation(keyPath: "transform.translation.x")
        scroll.fromValue = bounds.width
        scroll.toValue = -width
        scroll.duration = (bounds.width + width) / speed
        scroll.repeatCount = .infinity
        layer.add(scroll, forKey: "scroll")
    }
}
