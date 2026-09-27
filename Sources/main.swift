import AppKit
import IOKit
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

/// "Hottest CPU" as Stats computes it (and close to iStat Menus): the highest
/// per-core SMC temperature. The PMU die sensors read ~10° cooler than both.
final class CPUTemperature {
    // CPU core keys per Apple Silicon generation, from exelban/stats
    // Modules/Sensors/values.swift.
    private static let coreKeys: [String: String] = [
        "M1": "Tp09 Tp0T Tp01 Tp05 Tp0D Tp0H Tp0L Tp0P Tp0X Tp0b",
        "M2": "Tp1h Tp1t Tp1p Tp1l Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j",
        "M3": "Te05 Te0L Te0P Te0S Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E",
        "M4": "Te05 Te0S Te09 Te0H Tp01 Tp05 Tp09 Tp0D Tp0V Tp0Y Tp0b Tp0e",
        "M5":
            "Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y",
    ]
    private static let readKeyInfo: UInt8 = 9
    private static let readBytes: UInt8 = 5

    private var connection: io_connect_t = 0
    private var requests: [SMCParam] = []  // prepared once, replayed every read

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        defer { IOObjectRelease(service) }
        guard service != 0, IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS,
            let keys = Self.coreKeys[Self.chipGeneration()]
        else { return }

        for key in keys.split(separator: " ") {
            var request = SMCParam()
            request.key = Self.fourCC(key)
            request.data8 = Self.readKeyInfo
            guard let info = call(request)?.keyInfo,
                info.dataType == Self.fourCC("flt "), info.dataSize == 4
            else { continue }
            request.data8 = Self.readBytes
            request.keyInfo.dataSize = info.dataSize
            requests.append(request)
        }
    }

    func read() -> Double? {
        requests.compactMap { request -> Double? in
            guard let output = call(request) else { return nil }
            let value = withUnsafeBytes(of: output.bytes) { $0.loadUnaligned(as: Float.self) }
            return (10...120).contains(value) ? Double(value) : nil  // drop glitched sensors
        }.max()
    }

    private func call(_ input: SMCParam) -> SMCParam? {
        var input = input
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    /// "M3" from "Apple M3 Max".
    private static func chipGeneration() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let name = String(cString: brand)
        return name.range(of: #"M\d"#, options: .regularExpression).map { String(name[$0]) } ?? ""
    }

    private static func fourCC<S: StringProtocol>(_ code: S) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
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
