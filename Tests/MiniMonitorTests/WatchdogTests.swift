import Foundation
import Testing

@testable import MiniMonitor

struct StaleBrowserTests {
    @Test(arguments: [
        ("chrome-headless-", [], true),  // p_comm cuts chrome-headless-shell at 16
        ("chromedriver", [], true),
        ("Google Chrome f", ["--enable-automation", "--headless=new"], true),
        ("Google Chrome", ["--profile-directory=Default"], false),
        ("Google Chrome", [], false),
    ])
    func testBrowser(name: String, arguments: [String], expected: Bool) {
        #expect(Watchdog.isTestBrowser(name: name, arguments: arguments) == expected)
    }

    @Test func orphanedTestBrowsersWithTheirHelpers() {
        let processes = [
            ProcessSample(
                pid: 10, ppid: 1, name: "chrome-headless-", isTestBrowser: true, cpu: 0.2),
            ProcessSample(pid: 11, ppid: 10, name: "chrome-headless-", cpu: 0.5),
            ProcessSample(pid: 12, ppid: 11, name: "chrome-headless-", cpu: 0.1),
            // A test still running owns its browser: not stale.
            ProcessSample(pid: 20, ppid: 19, name: "chrome-headless-", isTestBrowser: true),
            // The user's own Chrome is an orphan too, but not a test browser.
            ProcessSample(pid: 30, ppid: 1, name: "Google Chrome"),
            ProcessSample(pid: 31, ppid: 30, name: "Google Chrome H", cpu: 2),
        ]
        let stale = Watchdog.staleBrowsers(in: processes)
        #expect(stale.map(\.root) == [10])
        #expect(stale.first?.processes.map(\.pid) == [10, 11, 12])
        #expect(abs((stale.first?.cpu ?? 0) - 0.8) < 1e-9)
    }

    private func browser(cpu: Double, root: pid_t = 10) -> StaleBrowser {
        StaleBrowser(root: root, processes: [ProcessSample(pid: root, cpu: cpu)])
    }

    @Test func alertsOnceItKeepsEatingCPUThenQuitsIt() {
        var watch = BrowserWatch()
        #expect(watch.update([browser(cpu: 0.5)], now: 0).alert.isEmpty)
        #expect(watch.update([browser(cpu: 0.5)], now: 30).alert.map(\.root) == [10])
        // Alerted once, then left alone until the grace period runs out.
        #expect(watch.update([browser(cpu: 0.5)], now: 60) == ([], []))
        #expect(watch.update([browser(cpu: 0.5)], now: 149).quit.isEmpty)
        #expect(watch.update([browser(cpu: 0)], now: 150).quit.map(\.root) == [10])
    }

    @Test func idleOrBrieflyBusyBrowsersAreOnlyListed() {
        var watch = BrowserWatch()
        for (now, cpu) in [(0.0, 0.5), (30, 0.01), (60, 0.5), (90, 0.02), (120, 0.5)] {
            #expect(watch.update([browser(cpu: cpu)], now: now) == ([], []))
        }
        #expect(watch.alerted.isEmpty)
    }

    @Test func forgetsBrowsersThatAreGone() {
        var watch = BrowserWatch()
        for now in [0.0, 30] { _ = watch.update([browser(cpu: 1)], now: now) }
        #expect(watch.alerted.keys.sorted() == [10])
        _ = watch.update([], now: 60)
        #expect(watch.alerted.isEmpty)

        for now in [90.0, 120] { _ = watch.update([browser(cpu: 1)], now: now) }
        watch.forget([10])
        #expect(watch.alerted.isEmpty)
    }
}

struct LoadWatchTests {
    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let away: Double = 600

    private func sample(cpu: Double = 0, gpu: Double = 0, pid: pid_t = 5, group: String? = nil)
        -> ProcessSample
    {
        ProcessSample(pid: pid, name: "Google Chrome H", cpu: cpu, gpu: gpu, group: group ?? chrome)
    }

    /// Feeds `scans` identical scans; returns every episode they started.
    private func run(
        _ watch: inout LoadWatch, _ processes: [ProcessSample], scans: Int, idle: Double
    ) -> [LoadWatch.Episode] {
        var started: [LoadWatch.Episode] = []
        for _ in 0..<scans { started += watch.update(processes, idle: idle) }
        return started
    }

    @Test func alertsWhenAnAppKeepsBusyWhileTheUserIsAway() {
        var watch = LoadWatch()
        let helpers = [sample(cpu: 0.7, pid: 5), sample(cpu: 0.6, pid: 6)]  // summed per app
        #expect(run(&watch, helpers, scans: watch.window - 1, idle: away).isEmpty)
        let started = watch.update(helpers, idle: away)
        #expect(started.map(\.group) == [chrome])
        #expect(started.first?.pid == 5)
        #expect(abs((started.first?.cpu ?? 0) - 1.3) < 1e-9)
        // One alert per episode.
        #expect(watch.update(helpers, idle: away).isEmpty)
        #expect(watch.active.count == 1)
    }

    @Test func staysQuietWhileTheUserIsAround() {
        var watch = LoadWatch()
        #expect(run(&watch, [sample(cpu: 2)], scans: 2 * watch.window, idle: 30).isEmpty)
        #expect(watch.active.isEmpty)
        // Walking away later still raises it.
        #expect(watch.update([sample(cpu: 2)], idle: away).count == 1)
    }

    @Test func recentlyStartedProcessesDontCount() {
        var watch = LoadWatch()
        var build = sample(cpu: 4)
        build.age = 10 * 60
        #expect(run(&watch, [build], scans: 2 * watch.window, idle: away).isEmpty)
    }

    @Test func gpuAloneCanRaiseIt() {
        var watch = LoadWatch()
        #expect(
            run(&watch, [sample(cpu: 0.1, gpu: 0.8)], scans: watch.window, idle: away).count == 1)
    }

    @Test func belowTheLimitsNothingHappens() {
        var watch = LoadWatch()
        #expect(
            run(&watch, [sample(cpu: 0.9, gpu: 0.4)], scans: 2 * watch.window, idle: away).isEmpty)
    }

    @Test func endsWhenTheLoadDropsAndCanStartAgain() {
        var watch = LoadWatch()
        _ = run(&watch, [sample(cpu: 2)], scans: watch.window, idle: away)
        #expect(watch.active.count == 1)
        _ = run(&watch, [sample(cpu: 0)], scans: watch.window * 2 / 3, idle: away)
        #expect(watch.active.isEmpty)
        #expect(run(&watch, [sample(cpu: 3)], scans: watch.window, idle: away).count == 1)
    }

    @Test func excludedAndIgnoredProcessesDontCount() {
        var watch = LoadWatch(ignored: ["/usr/libexec/mediaanalysisd"])
        let processes = [
            sample(cpu: 2, pid: 7, group: "/usr/libexec/mediaanalysisd"),
            sample(cpu: 2, pid: 8),
        ]
        for _ in 0..<watch.window { _ = watch.update(processes, idle: away, excluding: [8]) }
        #expect(watch.active.isEmpty)
    }

    @Test func ignoringEndsAnEpisode() {
        var watch = LoadWatch()
        _ = run(&watch, [sample(cpu: 2)], scans: watch.window, idle: away)
        watch.ignore(chrome)
        #expect(watch.active.isEmpty)
        #expect(run(&watch, [sample(cpu: 2)], scans: watch.window, idle: away).isEmpty)
        watch.unignore(chrome)
        #expect(run(&watch, [sample(cpu: 2)], scans: watch.window, idle: away).count == 1)
    }
}

struct ProcessHelperTests {
    @Test func procArgs() {
        var buffer: [UInt8] = [3, 0, 0, 0]
        buffer += Array("/bin/chrome".utf8) + [0, 0, 0, 0]
        for argument in ["/bin/chrome", "--enable-automation", "--headless", "PATH=/usr/bin"] {
            buffer += Array(argument.utf8) + [0]
        }
        #expect(
            Watchdog.arguments(fromProcArgs: buffer)
                == ["/bin/chrome", "--enable-automation", "--headless"])
        #expect(Watchdog.arguments(fromProcArgs: []).isEmpty)
    }

    @Test func psOutput() {
        let output = """
                1     0 Tue Nov 17 01:05:27 2026      81:13.78 /sbin/launchd
              742     1 Sun Nov  8 23:59:01 2026  1-02:03:04.50 /System/Library/CoreServices/TimeMachine/backupd
              900     1 Sun Nov 22 08:02:41 2026       0:00.21 /Library/Application Support/Some Daemon/daemon
            garbage
            """
        let rows = Watchdog.psRows(output)
        #expect(rows.map(\.pid) == [1, 742, 900])
        let launchd: Double = 81 * 60 + 13.78
        #expect(abs(rows[0].cpu - launchd) < 1e-9)
        let backupd: Double = 86_400 + 7_384.5  // 1 day, 2:03:04.5
        #expect(abs(rows[1].cpu - backupd) < 1e-9)
        #expect(rows[1].start == "Sun Nov 8 23:59:01 2026")
        #expect(rows[1].started != nil)
        #expect(rows[2].path == "/Library/Application Support/Some Daemon/daemon")
        #expect(Watchdog.cpuSeconds("0:00.21") == 0.21)
        #expect(Watchdog.cpuSeconds("x") == nil)
    }

    @Test func scannerReadsRootDaemonsThroughPS() {
        let scanner = ProcessScanner()
        #expect(scanner.scan().contains { $0.pid == 1 })  // launchd, owned by root
        scanner.readsOtherUsers = false
        #expect(!scanner.scan().contains { $0.pid == 1 })
    }

    @Test func gpuClientCreator() {
        #expect(Watchdog.pid(fromCreator: "pid 636, WindowServer") == 636)
        #expect(Watchdog.pid(fromCreator: "WindowServer") == nil)
    }

    @Test(arguments: [
        // Chrome's helpers count towards Chrome.
        (
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ),
        // A command in a terminal counts on its own, not towards the terminal.
        (
            "/Users/me/.local/share/mise/installs/node/24/bin/node",
            "/Applications/Rex.app/Contents/MacOS/Rex",
            "/Users/me/.local/share/mise/installs/node/24/bin/node"
        ),
        (
            "/usr/libexec/mediaanalysisd", "/usr/libexec/mediaanalysisd",
            "/usr/libexec/mediaanalysisd"
        ),
    ])
    func grouping(path: String, responsible: String, expected: String) {
        #expect(Watchdog.group(path: path, responsiblePath: responsible) == expected)
    }

    @Test func displayNames() {
        #expect(
            Watchdog.displayName(
                forPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
                == "Google Chrome")
        #expect(Watchdog.displayName(forPath: "/usr/libexec/mediaanalysisd") == "mediaanalysisd")
        #expect(Watchdog.displayName(forPath: "node") == "node")
        #expect(percent(1.4) == "140%")
    }

    @Test func scannerSeesThisProcessTree() {
        let scanner = ProcessScanner()
        let processes = scanner.scan()
        #expect(processes.count > 10)
        #expect(processes.contains { $0.pid == getppid() })
        #expect(processes.allSatisfy { $0.cpu == 0 })  // no deltas on the first scan
    }
}

struct SpikeTests {
    @Test func startsAndEndsOnlyAfterHoldingForTwoSamples() {
        var spike = SpikeWatch()
        // One high sample is noise; between the limits a spike carries on.
        let loads = [0.9, 0.3, 0.8, 0.75, 0.6, 0.4, 0.45]
        let states = loads.map { spike.update($0) }
        #expect(states == [false, false, false, true, true, true, false])
    }

    /// The case from Activity Monitor: a test's headless Chrome at 870% under node.
    private let processes = [
        ProcessSample(pid: 100, ppid: 50, name: "node", cpu: 0.99, group: "/opt/node/bin/node"),
        ProcessSample(pid: 101, ppid: 50, name: "node", cpu: 0.98, group: "/opt/node/bin/node"),
        ProcessSample(pid: 50, ppid: 40, name: "zsh", cpu: 0.02, group: "/bin/zsh"),
        ProcessSample(pid: 40, ppid: 1, name: "Rex"),
        ProcessSample(
            pid: 200, ppid: 100, name: "chrome-headless-", cpu: 0.5,
            group: "/x/chrome-headless-shell"
        ),
        ProcessSample(
            pid: 201, ppid: 200, name: "chrome-headless-", cpu: 8.2,
            group: "/x/chrome-headless-shell"
        ),
        ProcessSample(pid: 300, ppid: 1, name: "WindowServer", cpu: 0.66, group: "/w/WindowServer"),
        ProcessSample(pid: 301, ppid: 1, name: "idle", group: ""),
    ]

    @Test func busiestSumsAnAppsProcesses() {
        let busiest = Watchdog.busiest(processes, minCPU: 0.5)
        #expect(
            busiest.map(\.group) == [
                "/x/chrome-headless-shell", "/opt/node/bin/node", "/w/WindowServer",
            ])
        #expect(abs(busiest[0].cpu - 8.7) < 1e-9)
        #expect(busiest[0].top.pid == 201)
        #expect(Watchdog.busiest(processes, limit: 1).count == 1)
    }

    /// A real busy process, as a spike would see it.
    @Test func spikeScanNamesABusyProcess() throws {
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        defer {
            busy.terminate()
            busy.waitUntilExit()
        }
        let scanner = ProcessScanner()
        scanner.readsGPU = false
        _ = scanner.scan()
        Thread.sleep(forTimeInterval: 1)
        let processes = scanner.scan()
        // Whatever else the Mac is busy with may rank higher; find ours.
        let entry = Watchdog.busiest(processes, limit: .max).first {
            $0.top.pid == busy.processIdentifier
        }
        let found = try #require(entry)
        #expect(Watchdog.displayName(forPath: found.group) == "yes")
        #expect(found.cpu > 0.5)
        // Started by this test process, which the scanner leaves out of its own scans.
        #expect(found.top.ppid == getpid())
    }

    @Test func launcherSkipsTheAppsOwnProcesses() {
        let renderer = processes.first { $0.pid == 201 }!
        #expect(Watchdog.launcher(of: renderer, in: processes)?.pid == 100)  // node, not chrome
        let node = processes.first { $0.pid == 101 }!
        #expect(Watchdog.launcher(of: node, in: processes)?.name == "zsh")
        let windowServer = processes.first { $0.pid == 300 }!
        #expect(Watchdog.launcher(of: windowServer, in: processes) == nil)  // launchd
    }
}
