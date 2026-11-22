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
