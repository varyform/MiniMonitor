import AppKit
import ServiceManagement

// MARK: - Sensors

/// Aggregate CPU usage from Mach tick counters (one cheap syscall per sample).
final class CPULoad {
    private let host = mach_host_self()
    private var previous: host_cpu_load_info?

    /// Busy fraction 0...1 since the previous call; nil on the first call.
    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let old = previous else { return nil }

        let now = info.cpu_ticks
        let then = old.cpu_ticks  // (user, system, idle, nice)
        let busy = Double((now.0 &- then.0) &+ (now.1 &- then.1) &+ (now.3 &- then.3))
        let idle = Double(now.2 &- then.2)
        return busy + idle > 0 ? busy / (busy + idle) : 0
    }
}

/// Apple Silicon CPU die temperature, averaged over the PMU "tdie" sensors.
final class CPUTemperature {
    private static let temperatureEvent: Int64 = 15  // kIOHIDEventTypeTemperature
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var sensors: [IOHIDServiceClient] = []

    init() {
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
        else { return }
        var die: [IOHIDServiceClient] = []
        var device: [IOHIDServiceClient] = []
        for service in services where IOHIDServiceClientConformsTo(service, 0xff00, 5) != 0 {
            let name =
                IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? ""
            if name.hasPrefix("PMU tdie") {
                die.append(service)
            } else if name.hasPrefix("PMU tdev") {
                device.append(service)
            }
        }
        sensors = die.isEmpty ? device : die
    }

    func read() -> Double? {
        var sum = 0.0
        var count = 0
        for sensor in sensors {
            guard let event = IOHIDServiceClientCopyEvent(sensor, Self.temperatureEvent, 0, 0)
            else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(Self.temperatureEvent << 16))
            if value > 0 && value < 150 {
                sum += value
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let interval: TimeInterval = 2
    private let graphSize = NSSize(width: 36, height: 16)
    private let barWidth: CGFloat = 0.5  // one device pixel on Retina

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let loginItem = NSMenuItem(
        title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let cpu = CPULoad()
    private let temperature = CPUTemperature()
    private var history: [Double] = []
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        history = Array(repeating: 0, count: Int((graphSize.width - 4) / barWidth))

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular)
            button.imagePosition = .imageRight
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

        _ = cpu.sample()  // prime the tick baseline
        tick()
        start()
    }

    @objc private func start() {
        guard timer == nil else { return }
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
            history.removeFirst()
            history.append(load)
        }
        guard let button = statusItem.button else { return }
        let title = temperature.read().map { "\(Int($0.rounded()))°" } ?? "--°"
        if button.title != title { button.title = title }
        button.image = graphImage()
    }

    private func graphImage() -> NSImage {
        let samples = history
        let barWidth = barWidth
        let image = NSImage(size: graphSize, flipped: false) { rect in
            let frame = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSColor.black.withAlphaComponent(0.5).setStroke()
            frame.stroke()

            let plot = rect.insetBy(dx: 2, dy: 2)
            let bars = NSBezierPath()
            for (index, value) in samples.enumerated() {
                let height = max(barWidth, plot.height * min(value, 1))
                bars.appendRect(
                    NSRect(
                        x: plot.minX + CGFloat(index) * barWidth, y: plot.minY, width: barWidth,
                        height: height))
            }
            NSColor.black.setFill()
            bars.fill()
            return true
        }
        image.isTemplate = true  // follows menu bar light/dark and highlight
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            statusItem.menu = menu
            sender.performClick(nil)  // pops the menu; returns when it closes
            statusItem.menu = nil
        } else {
            openActivityMonitor()
        }
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
