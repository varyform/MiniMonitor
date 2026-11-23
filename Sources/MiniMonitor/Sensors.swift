import Foundation
import IOKit
import SMC

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
    static let coreKeys: [String: String] = [
        "M1": "Tp09 Tp0T Tp01 Tp05 Tp0D Tp0H Tp0L Tp0P Tp0X Tp0b",
        "M2": "Tp1h Tp1t Tp1p Tp1l Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j",
        "M3": "Te05 Te0L Te0P Te0S Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E",
        "M4": "Te05 Te0S Te09 Te0H Tp01 Tp05 Tp09 Tp0D Tp0V Tp0Y Tp0b Tp0e",
        "M5":
            "Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y",
    ]
    private static let readKeyInfo: UInt8 = 9
    private static let readBytes: UInt8 = 5
    private static let readKeyAtIndex: UInt8 = 8
    private static let maxKeys: UInt32 = 10_000

    private var connection: io_connect_t = 0
    private var requests: [SMCParam] = []  // prepared once, replayed every read

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        defer { IOObjectRelease(service) }
        guard service != 0, IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
        else { return }

        let keys =
            Self.coreKeys[Self.chipGeneration()]?.split(separator: " ").map(Self.fourCC) ?? []
        requests = keys.compactMap(request(for:))
        // macOS 27 renamed the M1's core sensors (Tp09 and friends are gone), so
        // when the table finds nothing, look the core keys up in the SMC itself.
        if requests.isEmpty { requests = discoveredCoreKeys().compactMap(request(for:)) }
    }

    /// A prepared read for a 4-byte float key; nil if the SMC has no such key.
    private func request(for key: UInt32) -> SMCParam? {
        var request = SMCParam()
        request.key = key
        request.data8 = Self.readKeyInfo
        guard let info = call(request)?.keyInfo,
            info.dataType == Self.fourCC("flt "), info.dataSize == 4
        else { return nil }
        request.data8 = Self.readBytes
        request.keyInfo.dataSize = info.dataSize
        return request
    }

    /// Every key the SMC lists that `isCoreKey` accepts (~1,000 keys, read once).
    private func discoveredCoreKeys() -> [UInt32] {
        // #KEY: the key count, a big-endian ui32.
        var count = SMCParam()
        count.key = Self.fourCC("#KEY")
        count.data8 = Self.readKeyInfo
        guard let size = call(count)?.keyInfo.dataSize, size == 4 else { return [] }
        count.data8 = Self.readBytes
        count.keyInfo.dataSize = size
        guard let output = call(count) else { return [] }
        let total = withUnsafeBytes(of: output.bytes) {
            $0.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
        }
        // A misread count mustn't stall launch with millions of calls; real SMCs list
        // a few thousand keys at most.
        return (0..<min(total, Self.maxKeys)).compactMap { index in
            var request = SMCParam()
            request.data8 = Self.readKeyAtIndex
            request.data32 = index
            guard let key = call(request)?.key, Self.isCoreKey(Self.name(of: key)) else {
                return nil
            }
            return key
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

    private static func chipGeneration() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0
        else { return "" }
        var brand = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0) == 0
        else { return "" }
        return generation(fromBrand: String(cString: brand))
    }

    /// "M3" from "Apple M3 Max"; "" for Intel.
    static func generation(fromBrand name: String) -> String {
        name.range(of: #"M\d"#, options: .regularExpression).map { String(name[$0]) } ?? ""
    }

    static func fourCC<S: StringProtocol>(_ code: S) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func name(of key: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((key >> $0) & 0xff) }, as: UTF8.self)
    }

    /// A per-core die sensor in the macOS 27 naming: Tc (E-core) or Tp (P-core), the
    /// core, then "x", the raw reading. ("a" is a smoothed copy; "b" and "z" add an
    /// offset of up to 15° on P-cores, which Stats' "hottest CPU" doesn't include.)
    static func isCoreKey(_ name: String) -> Bool {
        let chars = Array(name)
        return chars.count == 4 && chars[0] == "T" && (chars[1] == "c" || chars[1] == "p")
            && (chars[2].isNumber || chars[2].isLowercase) && chars[3] == "x"
    }
}
