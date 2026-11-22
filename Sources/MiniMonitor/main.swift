import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let interval: TimeInterval = 2
    // Stats' line chart widget is 32pt wide; this one is 20% wider. Height is the
    // menu bar height minus 2pt margins, as in Stats.
    private let graphSize = NSSize(width: 38, height: 18)
    private let graphGap: CGFloat = 8  // space between temperature and chart
    private let markSize: CGFloat = 5  // the dot that says something needs a look
    private let markGap: CGFloat = 3
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    private let historyCount = 60
    // Process scans keep running while the screen sleeps: that's when stale browsers
    // and runaway apps go unnoticed.
    // Every 30 s: a scan reads ~2,000 processes one syscall each (~30 ms).
    private let scanInterval: TimeInterval = 30
    private static let ignoredKey = "ignoredApps"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let loginItem = NSMenuItem(
        title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let cpu = CPULoad()
    private let temperature = CPUTemperature()
    private let scanner = ProcessScanner()
    private let alerts = Alerts()
    private var browserWatch = BrowserWatch()
    private var loadWatch = LoadWatch(
        ignored: Set(UserDefaults.standard.stringArray(forKey: AppDelegate.ignoredKey) ?? []))
    private var staleBrowsers: [StaleBrowser] = []
    private var history: [Double] = []  // oldest first, at most historyCount
    private var timer: Timer?

    private var needsAttention: Bool {
        !browserWatch.alerted.isEmpty || !loadWatch.active.isEmpty
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loginItem.target = self
        alerts.onQuitBrowsers = { [weak self] in self?.quitStaleBrowsers() }
        alerts.onIgnore = { [weak self] group in self?.ignore(group) }
        alerts.onShow = { [weak self] in self?.openActivityMonitor() }

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(stop), name: NSWorkspace.screensDidSleepNotification,
            object: nil)
        workspace.addObserver(
            self, selector: #selector(start), name: NSWorkspace.screensDidWakeNotification,
            object: nil)

        start()
        _ = scanner.scan()  // baseline for the first deltas
        let scans = Timer(
            timeInterval: scanInterval, target: self, selector: #selector(scan), userInfo: nil,
            repeats: true)
        scans.tolerance = scanInterval / 5
        RunLoop.main.add(scans, forMode: .common)
    }

    /// Redraws at once instead of a tick later. Re-primes the load baseline so the
    /// first sample covers one interval, not the time since launch or screen sleep.
    @objc private func start() {
        guard timer == nil else { return }
        _ = cpu.sample()
        redraw()
        let timer = Timer(
            timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil,
            repeats: true)
        timer.tolerance = interval / 4  // lets the system coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        if let load = cpu.sample() {
            history.append(load)
            if history.count > historyCount { history.removeFirst() }
        }
        redraw()
    }

    // MARK: - Watchdog

    @objc private func scan() {
        let processes = scanner.scan()
        staleBrowsers = Watchdog.staleBrowsers(in: processes)
        let browsers = browserWatch.update(staleBrowsers, now: ProcessInfo.processInfo.systemUptime)
        if !browsers.alert.isEmpty {
            alerts.staleBrowsers(browsers.alert, quitIn: browserWatch.quitDelay)
        }
        if !browsers.quit.isEmpty { quit(browsers.quit, notify: true) }

        // Stale browsers have their own alert; don't count them twice.
        let stale = Set(staleBrowsers.flatMap { $0.processes.map(\.pid) })
        for episode in loadWatch.update(processes, idle: Presence.idle, excluding: stale) {
            alerts.unusualLoad(episode, app: Watchdog.displayName(forPath: episode.group))
        }
        if timer != nil { redraw() }
    }

    @objc private func quitStaleBrowsers() {
        quit(staleBrowsers, notify: false)
    }

    private func quit(_ browsers: [StaleBrowser], notify: Bool) {
        Reaper.quit(browsers.flatMap(\.processes))
        let roots = Set(browsers.map(\.root))
        staleBrowsers.removeAll { roots.contains($0.root) }
        browserWatch.forget(roots)
        if notify { alerts.quitBrowsers(browsers.count) }
        redraw()
    }

    private func ignore(_ group: String) {
        loadWatch.ignore(group)
        alerts.clearLoad(group)
        saveIgnored()
        redraw()
    }

    @objc private func ignoreItem(_ sender: NSMenuItem) {
        if let group = sender.representedObject as? String { ignore(group) }
    }

    @objc private func unignoreItem(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? String else { return }
        loadWatch.unignore(group)
        saveIgnored()
    }

    private func saveIgnored() {
        UserDefaults.standard.set(loadWatch.ignored.sorted(), forKey: Self.ignoredKey)
    }

    // MARK: - Status item

    private func redraw() {
        guard let button = statusItem.button else { return }
        let text = temperature.read().map { "\(Int($0.rounded()))°" } ?? "--°"
        button.image = statusImage(text: text, mark: needsAttention)
        button.setAccessibilityLabel(needsAttention ? "\(text), needs attention" : text)
        button.toolTip = issues.isEmpty ? nil : issues.joined(separator: "\n")
    }

    /// One line per thing worth knowing about, for the tooltip.
    private var issues: [String] {
        var lines: [String] = []
        let eating = staleBrowsers.filter { browserWatch.alerted[$0.root] != nil }
        if !eating.isEmpty {
            lines.append(
                "Stale test browsers: \(eating.count), \(percent(eating.reduce(0) { $0 + $1.cpu })) CPU"
            )
        }
        for episode in loadWatch.active.values.sorted(by: { $0.cpu > $1.cpu }) {
            lines.append("\(Watchdog.displayName(forPath: episode.group)): \(usage(of: episode))")
        }
        return lines
    }

    private func usage(of episode: LoadWatch.Episode) -> String {
        var parts = ["\(percent(episode.cpu)) CPU"]
        if episode.gpu >= 0.05 { parts.append("\(percent(episode.gpu)) GPU") }
        return parts.joined(separator: ", ")
    }

    /// Temperature and chart drawn into one image, so the digits can be centred on
    /// the chart exactly instead of wherever NSButton puts its title.
    private func statusImage(text: String, mark: Bool) -> NSImage {
        let samples = history
        let slots = historyCount
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        let textX = mark ? markSize + markGap : 0
        let textWidth = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
        let capHeight = font.capHeight
        let chartX = textX + textWidth + graphGap
        let size = NSSize(width: chartX + graphSize.width, height: graphSize.height)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The handler runs once per display scale, so take the pixel size from the
            // context being drawn into rather than from one screen.
            let scale = context.userSpaceToDeviceSpaceTransform.a
            let pixel = 1 / (scale > 0 ? scale : 2)
            let half = pixel / 2

            if mark {
                NSColor.black.setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: 0, y: bounds.midY - self.markSize / 2, width: self.markSize,
                        height: self.markSize)
                ).fill()
            }

            // Digits centred on the chart, baseline snapped to a device pixel.
            let baseline = ((bounds.midY - capHeight / 2) / pixel).rounded() * pixel
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: textX, y: baseline)
            CTLineDraw(line, context)

            // Same geometry as Stats' LineChart widget in "frame" mode.
            let rect = NSRect(x: chartX, y: 0, width: bounds.width - chartX, height: bounds.height)
            let frame = NSBezierPath(
                roundedRect: rect.insetBy(dx: half, dy: half), xRadius: 2, yRadius: 2)
            frame.lineWidth = pixel

            if samples.count > 1 {
                let plot = NSRect(
                    x: frame.bounds.minX + half + pixel, y: half,
                    width: frame.bounds.width - 2 * half - pixel,
                    height: frame.bounds.height - half)
                let step = plot.width / CGFloat(slots - 1)
                // Newest sample on the right.
                let firstX = plot.minX + CGFloat(slots - samples.count) * step
                let points = samples.enumerated().map { index, value in
                    NSPoint(
                        x: firstX + CGFloat(index) * step,
                        y: plot.minY + (plot.height - half) * min(max(value, 0), 1))
                }

                let curve = NSBezierPath()
                curve.move(to: points[0])
                points.dropFirst().forEach(curve.line(to:))
                curve.lineWidth = pixel
                NSColor.black.setStroke()
                curve.stroke()

                let area = curve.copy() as! NSBezierPath
                area.line(to: NSPoint(x: points[points.count - 1].x, y: plot.minY))
                area.line(to: NSPoint(x: points[0].x, y: plot.minY))
                area.close()
                NSColor.black.setFill()
                area.fill()
            }

            NSColor.black.setStroke()
            frame.stroke()
            return true
        }
        image.isTemplate = true  // follows menu bar light/dark and highlight
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            rebuildMenu()
            statusItem.menu = menu
            sender.performClick(nil)  // pops the menu; returns when it closes
            statusItem.menu = nil
        } else {
            openActivityMonitor()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if !staleBrowsers.isEmpty {
            let cpu = staleBrowsers.reduce(0) { $0 + $1.cpu }
            let processes = staleBrowsers.reduce(0) { $0 + $1.processes.count }
            let title =
                staleBrowsers.count == 1
                ? "1 stale test browser" : "\(staleBrowsers.count) stale test browsers"
            menu.addItem(disabled("\(title): \(processes) processes, \(percent(cpu)) CPU"))
            menu.addItem(
                item("Quit Stale Browsers", action: #selector(quitStaleBrowsers)))
            menu.addItem(.separator())
        }

        let episodes = loadWatch.active.values.sorted { $0.cpu > $1.cpu }
        for episode in episodes {
            let name = Watchdog.displayName(forPath: episode.group)
            let entry = NSMenuItem(
                title: "\(name) is busy: \(usage(of: episode))", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(
                item("Show in Activity Monitor", action: #selector(showActivityMonitor)))
            let ignore = item("Ignore \(name)", action: #selector(ignoreItem))
            ignore.representedObject = episode.group
            submenu.addItem(ignore)
            entry.submenu = submenu
            menu.addItem(entry)
        }
        if !episodes.isEmpty { menu.addItem(.separator()) }

        if !loadWatch.ignored.isEmpty {
            let entry = NSMenuItem(title: "Ignored Apps", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(disabled("Choose one to watch it again"))
            for group in loadWatch.ignored.sorted() {
                let app = item(
                    Watchdog.displayName(forPath: group), action: #selector(unignoreItem))
                app.representedObject = group
                app.toolTip = group
                submenu.addItem(app)
            }
            entry.submenu = submenu
            menu.addItem(entry)
        }

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func showActivityMonitor() {
        openActivityMonitor()
    }

    private func openActivityMonitor() {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.ActivityMonitor")
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
