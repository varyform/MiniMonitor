import Testing

@testable import MiniMonitor

struct SensorTests {
    @Test(arguments: [
        ("Apple M1", "M1"),
        ("Apple M2 Pro", "M2"),
        ("Apple M3 Max", "M3"),
        ("Apple M4", "M4"),
        ("Apple M5 Ultra", "M5"),
        ("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", ""),
        ("", ""),
    ])
    func chipGeneration(brand: String, generation: String) {
        #expect(CPUTemperature.generation(fromBrand: brand) == generation)
    }

    @Test func everyGenerationHasCoreKeys() {
        for generation in ["M1", "M2", "M3", "M4", "M5"] {
            #expect(CPUTemperature.coreKeys[generation] != nil, "\(generation)")
        }
    }

    /// SMC keys are four ASCII characters; a typo would silently drop a core.
    @Test func coreKeysAreFourCharacterCodes() {
        for (generation, keys) in CPUTemperature.coreKeys {
            for key in keys.split(separator: " ") {
                #expect(key.utf8.count == 4 && key.allSatisfy(\.isASCII), "\(generation) \(key)")
            }
        }
    }

    @Test func fourCC() {
        #expect(CPUTemperature.fourCC("flt ") == 0x666C_7420)
        #expect(CPUTemperature.fourCC("Tp09") == 0x5470_3039)
    }

    @Test func keyName() {
        #expect(CPUTemperature.name(of: 0x5470_3039) == "Tp09")
    }

    @Test(arguments: [
        ("Tc0x", true), ("Tcax", true), ("Tp9x", true),
        ("Tp9a", false), ("Tp9z", false), ("TCMz", false), ("Th0x", false), ("Ts0x", false),
        ("Tp0", false),
    ])
    func coreKey(name: String, isCore: Bool) {
        #expect(CPUTemperature.isCoreKey(name) == isCore)
    }

    @Test func loadIsAFractionAfterTheFirstSample() throws {
        let load = CPULoad()
        #expect(load.sample() == nil)
        let busy = try #require(load.sample())
        #expect((0...1).contains(busy))
    }
}
