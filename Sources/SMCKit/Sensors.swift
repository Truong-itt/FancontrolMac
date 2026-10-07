import Foundation

public struct SensorReading: Identifiable, Equatable {
    /// Sensor id: a summary id (e.g. "cpu.avg") or a 4-character SMC key.
    public let id: String
    public let name: String
    public let detail: String
    public let celsius: Double

    public init(id: String, name: String, detail: String, celsius: Double) {
        self.id = id
        self.name = name
        self.detail = detail
        self.celsius = celsius
    }
}

/// A sensor group (CPU, GPU): its average and the detail rows inside it.
public struct SensorGroup: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let average: Double
    public let members: [SensorReading]

    public init(id: String, name: String, average: Double, members: [SensorReading]) {
        self.id = id
        self.name = name
        self.average = average
        self.members = members
    }
}

/// Catalog of temperature sensors, built from the SMC keys present on this machine.
///
/// Apple Silicon Macs expose hundreds of temperature keys (several per CPU core), so the catalog
/// rolls them up into summary groups; raw keys remain readable through `readRaw()`.
public final class SensorCatalog {
    public enum Combine {
        case average
        case maximum
    }

    public struct Definition {
        public let id: String
        public let name: String
        public let keys: [String]
        public let combine: Combine
    }

    private struct GroupDefinition {
        let id: String
        let name: String
        let averageID: String
        /// Summary rows shown inside the group (e.g. "cpu.max").
        let summaryIDs: [String]
    }

    public let definitions: [Definition]
    public let rawKeys: [String]
    private let groupDefinitions: [GroupDefinition]
    private let smc: SMC

    // Below this a sensor belongs to a powered-down part of the chip (it reads a few °C), not a real temperature.
    private static let validRange = 10.0..<150.0

    public init(smc: SMC) {
        self.smc = smc
        let rawKeys = smc.allKeys()
            .filter { $0.hasPrefix("T") && (try? smc.read($0))?.type == "flt " }
            .sorted()
        self.rawKeys = rawKeys

        // Keys whose third character is "x" (Tpx0, Tex1…) are the SMC's own aggregates; skip them to avoid double counting.
        func group(_ prefix: String) -> [String] {
            rawKeys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(2).hasPrefix("x") }
        }
        func single(_ key: String) -> [String] {
            rawKeys.contains(key) ? [key] : []
        }
        // The SMC reports each on-chip sensor as a few adjacent keys (CPU: 3, GPU: 2) whose values differ by
        // a few degrees. Use the second key as the representative so each sensor counts once.
        func representatives(_ keys: [String], variants: Int) -> [String] {
            guard keys.count % variants == 0 else { return keys }
            return stride(from: 0, to: keys.count, by: variants).map { keys[$0 + 1] }
        }

        // On M4 Pro the Tp1…/Tp2… keys duplicate the Tp0… sensors, so use only Tp0… when present.
        let performance = group("Tp0").isEmpty ? group("Tp") : group("Tp0")
        let efficiency = group("Te")
        let graphics = group("Tg")
        let performanceSensors = representatives(performance, variants: 3)
        let efficiencySensors = representatives(efficiency, variants: 3)
        let graphicsSensors = representatives(graphics, variants: 2)

        let candidates: [Definition] = [
            Definition(id: "cpu.avg", name: "CPU average", keys: performanceSensors + efficiencySensors, combine: .average),
            Definition(id: "cpu.max", name: "CPU hottest", keys: performance + efficiency, combine: .maximum),
            Definition(id: "cpu.p", name: "Performance cores (P)", keys: performanceSensors, combine: .average),
            Definition(id: "cpu.e", name: "Efficiency cores (E)", keys: efficiencySensors, combine: .average),
            Definition(id: "gpu.avg", name: "GPU average", keys: graphicsSensors, combine: .average),
            Definition(id: "gpu.max", name: "GPU hottest", keys: graphics, combine: .maximum),
            Definition(id: "battery", name: "Battery", keys: group("TB"), combine: .average),
            Definition(id: "ssd", name: "SSD", keys: single("TH0x"), combine: .average),
            Definition(id: "wifi", name: "Wi-Fi (Airport)", keys: single("TW0P"), combine: .average),
            Definition(id: "airflow.left", name: "Airflow left", keys: single("TaLP"), combine: .average),
            Definition(id: "airflow.right", name: "Airflow right", keys: single("TaRF"), combine: .average),
            Definition(id: "enclosure", name: "Enclosure / palm rest", keys: single("Ts0P") + single("Ts1P"), combine: .average),
        ]
        let available = candidates.filter { !$0.keys.isEmpty }
        definitions = available

        // No SMC key maps 1:1 to a core (M4 Pro: 15 sensors for 8 P cores, 2 for 4 E cores),
        // so a group shows only summary figures rather than listing every sensor.
        let groups = [
            GroupDefinition(id: "cpu", name: "CPU", averageID: "cpu.avg", summaryIDs: ["cpu.max", "cpu.p", "cpu.e"]),
            GroupDefinition(id: "gpu", name: "GPU", averageID: "gpu.avg", summaryIDs: ["gpu.max"]),
        ]
        groupDefinitions = groups.filter { group in available.contains { $0.id == group.averageID } }
    }

    /// Reads one sensor by summary id or by raw SMC key.
    public func read(id: String) -> Double? {
        if let definition = definitions.first(where: { $0.id == id }) {
            return read(definition)
        }
        guard rawKeys.contains(id) else { return nil }
        return value(of: id)
    }

    public func readSummary() -> [SensorReading] {
        definitions.compactMap { definition in
            guard let celsius = read(definition) else { return nil }
            let detail = definition.keys.count == 1 ? definition.keys[0] : ""
            return SensorReading(id: definition.id, name: definition.name, detail: detail, celsius: celsius)
        }
    }

    public func readGroups() -> [SensorGroup] {
        groupDefinitions.map { group in
            // A sleeping part of the chip (or a failed read) has no reading; keep the group and its rows with
            // NaN values so the list does not come and go.
            let average = read(id: group.averageID) ?? .nan
            let summaries = definitions.filter { group.summaryIDs.contains($0.id) }.map {
                SensorReading(id: $0.id, name: $0.name, detail: "", celsius: read($0) ?? .nan)
            }
            return SensorGroup(id: group.id, name: group.name, average: average, members: summaries)
        }
    }

    public func readRaw() -> [SensorReading] {
        rawKeys.compactMap { key in
            guard let celsius = value(of: key) else { return nil }
            return SensorReading(id: key, name: key, detail: Self.category(of: key), celsius: celsius)
        }
    }

    private func read(_ definition: Definition) -> Double? {
        let values = definition.keys.compactMap(value(of:))
        guard !values.isEmpty else { return nil }
        switch definition.combine {
        case .average: return values.reduce(0, +) / Double(values.count)
        case .maximum: return values.max()
        }
    }

    private func value(of key: String) -> Double? {
        guard let value = smc.readNumber(key), Self.validRange.contains(value) else { return nil }
        return value
    }

    private static func category(of key: String) -> String {
        switch key.prefix(2) {
        case "Tp": return "CPU performance core"
        case "Te": return "CPU efficiency core"
        case "Tg": return "GPU"
        case "TB": return "Battery"
        case "TH": return "SSD"
        case "TW": return "Wi-Fi"
        case "Ta": return "Airflow"
        default: return ""
        }
    }
}
