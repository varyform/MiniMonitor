import Foundation

/// One process as one scan saw it.
struct ProcessSample: Equatable {
    var pid: pid_t
    var ppid: pid_t = 1
    var name = ""  // p_comm: at most 16 characters
    /// Started by a test run: headless or automated Chrome, or chromedriver. Only
    /// worked out for orphans, the only place it matters, since it costs a sysctl.
    var isTestBrowser = false
    var start: UInt64 = 0  // mach absolute time; tells a reused pid apart
    var age: TimeInterval = .infinity
    var cpu: Double = 0  // cores, on average since the previous scan
    var gpu: Double = 0  // share of GPU time since the previous scan
    /// What the load counts towards: the app for its helpers, else the executable.
    /// Empty for processes too idle to be worth resolving.
    var group = ""
}

/// A test browser whose test run is gone: an orphan (adopted by launchd) with
/// everything it started.
struct StaleBrowser: Equatable {
    var root: pid_t
    var processes: [ProcessSample]  // the root first, then its descendants
    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
}

enum Watchdog {
    /// The same test the projects' own sweeps use (homeflow's StaleBrowsers,
    /// nostalgia's reap): headless shell, chromedriver, or Chrome under automation.
    /// The user's own Chrome is an orphan too, but never carries the flag.
    static func isTestBrowser(name: String, arguments: [String]) -> Bool {
        name.hasPrefix("chrome-headless") || name == "chromedriver"
            || arguments.contains("--enable-automation")
    }

    static func staleBrowsers(in processes: [ProcessSample]) -> [StaleBrowser] {
        let children = Dictionary(grouping: processes, by: \.ppid)
        func tree(_ process: ProcessSample) -> [ProcessSample] {
            [process] + (children[process.pid] ?? []).flatMap(tree)
        }
        return processes.filter { $0.ppid == 1 && $0.isTestBrowser }
            .map { StaleBrowser(root: $0.pid, processes: tree($0)) }
    }

    /// argv from a KERN_PROCARGS2 buffer: argc, the executable path, NUL padding,
    /// then argc NUL-terminated strings (the environment follows).
    static func arguments(fromProcArgs buffer: [UInt8]) -> [String] {
        guard buffer.count > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = 4
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < buffer.count {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }

    /// 636 from an IOAccelerator client's "pid 636, WindowServer".
    static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        return pid_t(creator.dropFirst(4).prefix(while: \.isNumber))
    }

    /// A helper inside its responsible app's bundle counts towards the app (Chrome's
    /// renderers towards Chrome). Anything else, such as a command run in a terminal,
    /// counts on its own rather than towards the terminal.
    static func group(path: String, responsiblePath: String) -> String {
        guard let bundle = responsiblePath.range(of: ".app/") else { return path }
        return path.hasPrefix(responsiblePath[..<bundle.upperBound]) ? responsiblePath : path
    }

    struct PSRow: Equatable {
        var pid: pid_t
        var ppid: pid_t
        var start: String  // lstart as printed; tells a reused pid apart
        var started: Date?
        var cpu: Double  // seconds, user + system
        var path: String
    }

    /// Rows of `ps -o pid=,ppid=,lstart=,time=,comm=` (LC_ALL=C), e.g.
    /// "  629     1 Tue Nov 17 01:05:27 2026     138:55.83 /usr/sbin/bluetoothd".
    static func psRows(_ output: String) -> [PSRow] {
        output.split(separator: "\n").compactMap { line in
            var rest = Substring(line)
            var fields: [Substring] = []
            while fields.count < 8 {
                rest = rest.drop { $0 == " " }
                let field = rest.prefix { $0 != " " }
                guard !field.isEmpty else { return nil }
                fields.append(field)
                rest = rest.dropFirst(field.count)
            }
            let path = rest.drop { $0 == " " }
            guard !path.isEmpty, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]),
                let cpu = cpuSeconds(fields[7])
            else { return nil }
            let start = fields[2...6].joined(separator: " ")
            return PSRow(
                pid: pid, ppid: ppid, start: start, started: lstart.date(from: start), cpu: cpu,
                path: String(path))
        }
    }

    /// Seconds from ps's "[dd-][hh:]mm:ss.ss".
    static func cpuSeconds<S: StringProtocol>(_ text: S) -> Double? {
        var clock = Substring(text)
        var days = 0.0
        if let dash = clock.firstIndex(of: "-") {
            guard let value = Double(clock[..<dash]) else { return nil }
            days = value
            clock = clock[clock.index(after: dash)...]
        }
        var seconds = 0.0
        for part in clock.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }

    private static let lstart: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    /// An app (or executable) and the CPU it uses, its helpers summed.
    struct Busy: Equatable {
        var group: String
        var cpu: Double  // cores
        var top: ProcessSample  // its busiest process
    }

    static func busiest(_ processes: [ProcessSample], limit: Int = 3, minCPU: Double = 0)
        -> [Busy]
    {
        var totals: [String: Busy] = [:]
        for process in processes where !process.group.isEmpty && process.cpu > 0 {
            var busy = totals[process.group] ?? Busy(group: process.group, cpu: 0, top: process)
            busy.cpu += process.cpu
            if process.cpu > busy.top.cpu { busy.top = process }
            totals[process.group] = busy
        }
        return Array(
            totals.values.filter { $0.cpu >= minCPU }.sorted { $0.cpu > $1.cpu }.prefix(limit))
    }

    /// What started `process`: its nearest ancestor that isn't more of the same (a
    /// browser's own processes, the app it belongs to). Nil when that's launchd.
    static func launcher(of process: ProcessSample, in processes: [ProcessSample])
        -> ProcessSample?
    {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }) { first, _ in first }
        var current = process
        for _ in 0..<64 {
            guard let parent = byPid[current.ppid], parent.pid > 1 else { return nil }
            let same =
                parent.name == process.name
                || (!parent.group.isEmpty && parent.group == process.group)
            if !same { return parent }
            current = parent
        }
        return nil
    }

    /// "Google Chrome" for an app's executable, else the executable's name.
    static func displayName(forPath path: String) -> String {
        let components = path.split(separator: "/")
        if let app = components.last(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return components.last.map(String.init) ?? path
    }
}

/// A big CPU spike: total load high for a couple of samples, over once it has been
/// well below for as long, so the marquee doesn't flicker on and off at the edge.
struct SpikeWatch {
    var on = 0.7  // share of all cores
    var off = 0.5
    var sustain = 2  // samples: 4 s at one every 2 s

    private(set) var isSpiking = false
    private var streak = 0

    mutating func update(_ load: Double) -> Bool {
        let crossing = isSpiking ? load < off : load >= on
        streak = crossing ? streak + 1 : 0
        if streak >= sustain {
            isSpiking.toggle()
            streak = 0
        }
        return isSpiking
    }
}

/// Stale test browsers: alerts once one keeps eating CPU, and quits it when the
/// alert has gone unanswered for `quitDelay`. Idle ones are only listed.
struct BrowserWatch {
    var minCPU = 0.1  // cores, in every one of `sustain` scans in a row
    var sustain = 2
    var quitDelay: TimeInterval = 120

    private var busyScans: [pid_t: Int] = [:]
    private(set) var alerted: [pid_t: TimeInterval] = [:]  // root → when

    /// Drops quit browsers at once rather than at the next scan, so the dot goes.
    mutating func forget(_ roots: Set<pid_t>) {
        busyScans = busyScans.filter { !roots.contains($0.key) }
        alerted = alerted.filter { !roots.contains($0.key) }
    }

    /// - Returns: browsers to alert about now, and alerted ones to quit now.
    mutating func update(_ browsers: [StaleBrowser], now: TimeInterval)
        -> (alert: [StaleBrowser], quit: [StaleBrowser])
    {
        let roots = Set(browsers.map(\.root))
        busyScans = busyScans.filter { roots.contains($0.key) }
        alerted = alerted.filter { roots.contains($0.key) }

        var alert: [StaleBrowser] = []
        var quit: [StaleBrowser] = []
        for browser in browsers {
            if let since = alerted[browser.root] {
                if now - since >= quitDelay { quit.append(browser) }
                continue
            }
            let busy = browser.cpu >= minCPU ? busyScans[browser.root, default: 0] + 1 : 0
            busyScans[browser.root] = busy
            if busy >= sustain {
                alerted[browser.root] = now
                alert.append(browser)
            }
        }
        return (alert, quit)
    }
}

/// Everything else: an app that keeps the CPU or GPU busy for a whole window while
/// the user is away. Processes started recently are the user's own doing and don't
/// count, and while the user is around nothing new is raised.
struct LoadWatch {
    struct Episode: Equatable {
        var group: String
        var pid: pid_t  // its busiest process
        var name: String  // that process's name
        var cpu: Double  // cores, averaged over the window
        var gpu: Double
    }

    var window = 10  // scans: 5 minutes at one every 30 s
    var cpuLimit = 1.0  // cores
    var gpuLimit = 0.5  // share of the GPU
    var minAge: TimeInterval = 15 * 60
    var minIdle: TimeInterval = 5 * 60
    private(set) var ignored: Set<String> = []

    private var history: [String: [(cpu: Double, gpu: Double)]] = [:]  // oldest first
    private(set) var active: [String: Episode] = [:]

    init(ignored: Set<String> = []) {
        self.ignored = ignored
    }

    mutating func ignore(_ group: String) {
        ignored.insert(group)
        history[group] = nil
        active[group] = nil
    }

    mutating func unignore(_ group: String) {
        ignored.remove(group)
    }

    /// - Returns: the episodes that just started, to alert about.
    mutating func update(
        _ processes: [ProcessSample], idle: TimeInterval, excluding excluded: Set<pid_t> = []
    ) -> [Episode] {
        var totals: [String: (cpu: Double, gpu: Double, top: ProcessSample)] = [:]
        for process in processes
        where process.age >= minAge && !process.group.isEmpty
            && !excluded.contains(process.pid) && !ignored.contains(process.group)
        {
            var total = totals[process.group] ?? (0, 0, process)
            total.cpu += process.cpu
            total.gpu += process.gpu
            if process.cpu + process.gpu > total.top.cpu + total.top.gpu { total.top = process }
            totals[process.group] = total
        }

        var started: [Episode] = []
        for group in Set(history.keys).union(totals.keys) {
            let total = totals[group]
            var samples = history[group] ?? []
            // Not worth tracking until it does something.
            if samples.isEmpty && max(total?.cpu ?? 0, total?.gpu ?? 0) < 0.05 { continue }
            samples.append((total?.cpu ?? 0, total?.gpu ?? 0))
            if samples.count > window { samples.removeFirst(samples.count - window) }
            if samples.count == window && samples.allSatisfy({ max($0.cpu, $0.gpu) < 0.01 }) {
                history[group] = nil
                active[group] = nil
                continue
            }
            history[group] = samples

            let cpu = samples.reduce(0) { $0 + $1.cpu } / Double(samples.count)
            let gpu = samples.reduce(0) { $0 + $1.gpu } / Double(samples.count)
            guard samples.count == window, cpu > cpuLimit || gpu > gpuLimit else {
                active[group] = nil
                continue
            }
            if var episode = active[group] {
                episode.cpu = cpu
                episode.gpu = gpu
                active[group] = episode
            } else if idle >= minIdle, let top = total?.top {
                let episode = Episode(
                    group: group, pid: top.pid, name: top.name, cpu: cpu, gpu: gpu)
                active[group] = episode
                started.append(episode)
            }
        }
        return started
    }
}
