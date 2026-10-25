import Foundation
import SMCKit

let usage = """
Usage:
  fanctl status                              Show fans, sensors and control modes
  fanctl sensors [--all]                     Show sensors (--all: every SMC temperature key)
  fanctl set <fan|all> auto                  Return the fan to automatic
  fanctl set <fan|all> <rpm>                 Hold a fixed speed
  fanctl set <fan|all> medium                Run at 50% of the fan's maximum speed
  fanctl set <fan|all> max                   Run at 100% (the fan's maximum speed)
  fanctl set <fan|all> sensor <id> <t1> <t2>
                                             Follow a sensor: minimum RPM at t1°C, maximum at t2°C
  fanctl read <key>...                       Read raw SMC keys (e.g. F0Md F0Tg Ftst)
Fans are numbered from 0. The set command needs the helper (scripts/install-helper.sh).
"""

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

func describe(_ mode: FanControlMode) -> String {
    switch mode {
    case .auto: return "auto"
    case .constant(let rpm): return "fixed \(rpm) RPM"
    case .sensor(let id, let minTemp, let maxTemp):
        return "following \(id) (\(Int(minTemp))–\(Int(maxTemp))°C)"
    case .curve(let curves):
        return "curve (" + curves.map(\.sensorID).joined(separator: ", ") + ")"
    }
}

func printSensors(_ readings: [SensorReading]) {
    for reading in readings {
        let name = reading.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        let id = reading.id.padding(toLength: 14, withPad: " ", startingAt: 0)
        print("  \(name) \(id) \(String(format: "%5.1f", reading.celsius))°C  \(reading.detail)")
    }
}

func printStatus(smc: SMC) {
    let helper = try? HelperClient.send(.status)
    print("Fans:")
    for fan in smc.fans() {
        let control: String
        if let helper, fan.id < helper.modes.count {
            control = describe(helper.modes[fan.id]) + (helper.errors[fan.id].map { " — ERROR: \($0)" } ?? "")
        } else {
            control = fan.manual ? "forced (not through the helper)" : "auto"
        }
        print("  [\(fan.id)] \(fan.name): \(Int(fan.actualRPM)) RPM "
            + "(min \(Int(fan.minRPM)), max \(Int(fan.maxRPM))) — \(control)")
    }
    print(helper == nil ? "Helper: not running (read-only)" : "Helper: running")
}

func parseMode(_ arguments: [String]) -> FanControlMode? {
    guard let first = arguments.first else { return nil }
    if first == "auto", arguments.count == 1 { return .auto }
    if let rpm = Int(first), arguments.count == 1 { return .constant(rpm: rpm) }
    if first == "sensor", arguments.count == 4, let minTemp = Double(arguments[2]), let maxTemp = Double(arguments[3]) {
        return .sensor(sensorID: arguments[1], minTemp: minTemp, maxTemp: maxTemp)
    }
    return nil
}

let arguments = Array(CommandLine.arguments.dropFirst())
let smc: SMC
do {
    smc = try SMC()
} catch {
    fail("\(error)")
}

switch arguments.first {
case "status", nil:
    printStatus(smc: smc)
    print("Sensors:")
    printSensors(SensorCatalog(smc: smc).readSummary())

case "sensors":
    let catalog = SensorCatalog(smc: smc)
    printSensors(catalog.readSummary())
    if arguments.contains("--all") { printSensors(catalog.readRaw()) }

case "read":
    for key in arguments.dropFirst() {
        do {
            let value = try smc.read(key)
            let hex = value.bytes.map { String(format: "%02x", $0) }.joined()
            print("\(key) [\(value.type)] \(value.number.map { String($0) } ?? "-") 0x\(hex)")
        } catch {
            print("\(error)")
        }
    }

case "set":
    // A share of each fan's maximum, for the presets that depend on the fan.
    let fraction: Double? = arguments.count == 3 ? ["medium": 0.5, "max": 1][arguments[2]] : nil
    guard arguments.count >= 3, let requested = fraction != nil ? .auto : parseMode(Array(arguments.dropFirst(2))) else {
        fail(usage)
    }
    let fans: [Int]
    if arguments[1] == "all" {
        fans = Array(0..<smc.fanCount())
    } else if let fan = Int(arguments[1]) {
        fans = [fan]
    } else {
        fail(usage)
    }
    do {
        let limits = smc.fans()
        for fan in fans {
            guard fraction == nil || limits.indices.contains(fan) else { fail("There is no fan \(fan)") }
            var mode = requested
            if let fraction {
                mode = .constant(rpm: Int(max(limits[fan].maxRPM * fraction, limits[fan].minRPM)))
            }
            _ = try HelperClient.send(.set(fan: fan, mode: mode))
            print("Fan \(fan): \(describe(mode))")
        }
    } catch {
        fail("\(error)")
    }

default:
    fail(usage)
}
