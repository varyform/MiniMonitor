import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// The app a process belongs to as Activity Monitor groups it (helpers → their app,
/// a terminal's commands → the terminal). Private but stable libsystem SPI.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePid(_ pid: pid_t) -> pid_t

/// Per-process CPU and GPU use, from deltas between scans. Processes owned by other
/// users can't be read without root, so system daemons running as root are left out.
final class ProcessScanner {
    private let ownPid = getpid()
    private let secondsPerTick: Double
    private var previous: [pid_t: (start: UInt64, cpu: UInt64, gpu: UInt64)] = [:]
    private var lastScan: TimeInterval?
    private var paths: [pid_t: String] = [:]
    private var pids = [pid_t](repeating: 0, count: 4096)
    /// Pids we may not read (other users' daemons), skipped until the next retry so
    /// each scan doesn't pay for hundreds of failing calls.
    private var unreadable: Set<pid_t> = []
    private var scansUntilRetry = 0

    init() {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    func scan() -> [ProcessSample] {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = lastScan.map { now - $0 } ?? 0
        lastScan = now

        let gpuTimes = Self.gpuTimes()
        var count = listPids()
        if count >= pids.count {
            pids = .init(repeating: 0, count: count * 2)
            count = listPids()
        }
        let clock = mach_absolute_time()
        if scansUntilRetry == 0 {
            unreadable = []
            scansUntilRetry = 10
        }
        scansUntilRetry -= 1

        var samples: [ProcessSample] = []
        samples.reserveCapacity(count)
        var seen: [pid_t: (start: UInt64, cpu: UInt64, gpu: UInt64)] = [:]
        for pid in pids.prefix(count) where pid > 0 && pid != ownPid && !unreadable.contains(pid) {
            guard let usage = Self.usage(of: pid) else {
                unreadable.insert(pid)
                continue
            }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else {
                continue
            }

            let start = usage.ri_proc_start_abstime
            let cpu = usage.ri_user_time + usage.ri_system_time  // mach ticks on Apple Silicon
            let gpu = gpuTimes[pid] ?? 0  // nanoseconds
            seen[pid] = (start, cpu, gpu)

            var sample = ProcessSample(pid: pid)
            sample.ppid = pid_t(info.pbsi_ppid)
            sample.name = withUnsafeBytes(of: info.pbsi_comm) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            sample.start = start
            sample.age = clock > start ? Double(clock - start) * secondsPerTick : 0
            if interval > 0, let old = previous[pid], old.start == start {
                if cpu > old.cpu { sample.cpu = Double(cpu - old.cpu) * secondsPerTick / interval }
                if gpu > old.gpu { sample.gpu = Double(gpu - old.gpu) / 1e9 / interval }
            }
            if sample.ppid == 1, sample.name.lowercased().contains("chrom") {
                sample.isTestBrowser = Watchdog.isTestBrowser(
                    name: sample.name, arguments: Self.arguments(of: pid))
            }
            if sample.cpu >= 0.01 || sample.gpu >= 0.01 {
                sample.group = group(of: pid, name: sample.name)
            }
            samples.append(sample)
        }
        previous = seen
        paths = paths.filter { seen[$0.key] != nil }
        return samples
    }

    /// Whether `process` is still the very process that was scanned, so a signal
    /// can't hit a new one that took over its pid.
    static func isRunning(_ process: ProcessSample) -> Bool {
        usage(of: process.pid)?.ri_proc_start_abstime == process.start
    }

    private func listPids() -> Int {
        Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    }

    private func group(of pid: pid_t, name: String) -> String {
        let path = path(of: pid)
        guard !path.isEmpty else { return name }
        let responsible = responsiblePid(pid)
        guard responsible > 0, responsible != pid else { return path }
        let responsiblePath = self.path(of: responsible)
        return responsiblePath.isEmpty
            ? path : Watchdog.group(path: path, responsiblePath: responsiblePath)
    }

    private func path(of pid: pid_t) -> String {
        if let path = paths[pid] { return path }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        paths[pid] = path
        return path
    }

    private static func usage(of pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return Watchdog.arguments(fromProcArgs: Array(buffer.prefix(size)))
    }

    /// GPU time per pid (nanoseconds, summed over its command queues), as Activity
    /// Monitor shows it: each GPU client in the IORegistry names its creator.
    private static func gpuTimes() -> [pid_t: UInt64] {
        var accelerators: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators)
                == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(accelerators) }

        var times: [pid_t: UInt64] = [:]
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard
                IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients)
                    == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard
                    let creator = property(client, "IOUserClientCreator") as? String,
                    let pid = Watchdog.pid(fromCreator: creator),
                    let queues = property(client, "AppUsage") as? [[String: Any]]
                else { continue }
                for queue in queues {
                    times[pid, default: 0] +=
                        (queue["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                }
            }
        }
        return times
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}

/// Whether the user is at the Mac.
enum Presence {
    /// Seconds since the last keyboard, mouse or trackpad input; 0 while something
    /// keeps the display awake on purpose (a video, a call, a presentation), since
    /// then the user is watching rather than away.
    static var idle: TimeInterval {
        if displayHeldAwake { return 0 }
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    private static var displayHeldAwake: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
            let assertions = status?.takeRetainedValue() as? [String: Int]
        else { return false }
        // kIOPMAssertionTypePreventUserIdleDisplaySleep and its old name (CFSTR macros,
        // which Swift doesn't import).
        return (assertions["PreventUserIdleDisplaySleep"] ?? 0) > 0
            || (assertions["NoDisplaySleepAssertion"] ?? 0) > 0
    }
}

enum Reaper {
    /// SIGTERM, then SIGKILL for whatever is still there 5 seconds later.
    static func quit(_ processes: [ProcessSample]) {
        let targets = processes.filter(ProcessScanner.isRunning)
        for process in targets { kill(process.pid, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            for process in targets where ProcessScanner.isRunning(process) {
                kill(process.pid, SIGKILL)
            }
        }
    }
}
