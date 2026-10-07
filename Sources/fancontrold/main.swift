import Foundation
import SMCKit

// Root helper, run as a LaunchDaemon. It is the only process that writes to the SMC:
// it receives the desired mode for each fan over a Unix socket and keeps that mode applied.

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    print("[fancontrold] \(message)")
}

struct HelperError: Error, CustomStringConvertible {
    let description: String
}

final class Controller {
    private let smc: SMC
    private let writer: FanWriter
    private lazy var catalog = SensorCatalog(smc: smc)

    // State shared with the socket handler threads.
    private let stateLock = NSLock()
    private var modes: [FanControlMode]
    private var errors: [String?]

    // Used only inside the control loop (with passLock held).
    private let passLock = NSLock()
    private var owned: [Bool]
    private var lastRPM: [Double?]
    private var smoothedTemp: [[String: Double]]
    /// The mode the control loop is applying right now, to notice when it is superseded mid-way.
    private var applying: FanControlMode?
    private let wake = DispatchSemaphore(value: 0)

    // In sensor-driven modes, ignore changes smaller than this so the fan does not keep changing speed.
    private static let sensorTolerance = 50.0
    // CPU core temperatures jump quickly; smooth them (exponential moving average) so the fan does not surge.
    private static let smoothingFactor = 0.25
    // A running fan only stops once the temperature is this many degrees below the curve's off point,
    // so it does not switch on and off around the threshold.
    private static let offHysteresis = 3.0
    private static let interval: TimeInterval = 2

    let fanCount: Int

    init(smc: SMC) {
        self.smc = smc
        writer = FanWriter(smc: smc)
        fanCount = smc.fanCount()
        modes = Array(repeating: .auto, count: fanCount)
        errors = Array(repeating: nil, count: fanCount)
        owned = Array(repeating: false, count: fanCount)
        lastRPM = Array(repeating: nil, count: fanCount)
        smoothedTemp = Array(repeating: [:], count: fanCount)
    }

    func snapshot() -> (modes: [FanControlMode], errors: [String?]) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (modes, errors)
    }

    func set(fan: Int, mode: FanControlMode) throws {
        guard (0..<fanCount).contains(fan) else { throw HelperError(description: "There is no fan \(fan)") }
        if case .sensor(_, let minTemp, let maxTemp) = mode, maxTemp <= minTemp {
            throw HelperError(description: "The maximum temperature must be above the start temperature")
        }
        if case .curve(let curves) = mode, curves.isEmpty || curves.contains(where: { $0.points.isEmpty }) {
            throw HelperError(description: "The fan curve has no points")
        }
        stateLock.lock()
        modes[fan] = mode
        errors[fan] = nil
        stateLock.unlock()
        wake.signal()
    }

    func run() {
        while true {
            let current = snapshot().modes
            passLock.lock()
            for (fan, mode) in current.enumerated() {
                // Skip a mode that was replaced while an earlier fan was being handled; the next pass picks up the new one.
                guard isWanted(mode, for: fan) else { continue }
                let error = apply(mode, to: fan)
                stateLock.lock()
                // Drop the result if the mode changed while it was being applied.
                if modes[fan] == mode { errors[fan] = error }
                stateLock.unlock()
            }
            passLock.unlock()

            if current.allSatisfy({ $0 == .auto }) {
                wake.wait()
            } else {
                _ = wake.wait(timeout: .now() + Self.interval)
            }
        }
    }

    /// Returns every fan to automatic. Call before the helper exits.
    func releaseAll() {
        passLock.lock(); defer { passLock.unlock() }
        for fan in 0..<fanCount where owned[fan] {
            release(fan)
        }
    }

    private func isWanted(_ mode: FanControlMode, for fan: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return modes[fan] == mode
    }

    private func apply(_ mode: FanControlMode, to fan: Int) -> String? {
        applying = mode
        do {
            switch mode {
            case .auto:
                if owned[fan] { release(fan) }
            case .constant(let rpm):
                smoothedTemp[fan] = [:]
                try force(fan, rpm: Double(rpm), tolerance: 0, belowMinimum: true)
            case .sensor(let sensorID, let minTemp, let maxTemp):
                guard let reading = catalog.read(id: sensorID) else {
                    throw HelperError(description: "Could not read sensor \(sensorID)")
                }
                let temperature = smooth(reading, sensorID: sensorID, fan: fan)
                let fraction = max(0, min(1, (temperature - minTemp) / (maxTemp - minTemp)))
                let limits = try self.limits(of: fan)
                let rpm = limits.lowerBound + fraction * (limits.upperBound - limits.lowerBound)
                try force(fan, rpm: rpm, tolerance: Self.sensorTolerance)
            case .curve(let curves):
                var target: Double?
                var targetIfWarmer = 0.0
                for curve in curves {
                    guard let reading = catalog.read(id: curve.sensorID) else { continue }
                    let temperature = smooth(reading, sensorID: curve.sensorID, fan: fan)
                    target = max(target ?? 0, curve.rpm(at: temperature))
                    targetIfWarmer = max(targetIfWarmer, curve.rpm(at: temperature + Self.offHysteresis))
                }
                guard var rpm = target else {
                    throw HelperError(description: "Could not read any of the curve's sensors")
                }
                let running = (lastRPM[fan] ?? 0) > 0
                if rpm <= 0, running, targetIfWarmer > 0 { rpm = targetIfWarmer }
                try force(fan, rpm: rpm, tolerance: Self.sensorTolerance, belowMinimum: true)
            }
            return nil
        } catch is FanWriter.Cancelled {
            // The user changed their mind while the fan was being taken over; drop it and let the next pass act.
            if owned[fan] { release(fan) }
            return nil
        } catch {
            // If the fan cannot be controlled, return it to automatic rather than leave it stuck at the old speed.
            if owned[fan] { release(fan) }
            log("fan \(fan): \(error)")
            return "\(error)"
        }
    }

    private func smooth(_ reading: Double, sensorID: String, fan: Int) -> Double {
        let previous = smoothedTemp[fan][sensorID] ?? reading
        let temperature = previous + Self.smoothingFactor * (reading - previous)
        smoothedTemp[fan][sensorID] = temperature
        return temperature
    }

    private func force(_ fan: Int, rpm requested: Double, tolerance: Double, belowMinimum: Bool = false) throws {
        let limits = try self.limits(of: fan)
        // Fixed speeds and curves may go below the advertised minimum RPM (0 = fan off), since the real fan
        // runs slower than that; the linear sensor mode stays within the fan's limits.
        let rpm = max(belowMinimum ? 0 : limits.lowerBound, min(limits.upperBound, requested))

        // Skip if the SMC still holds the value we wrote (it may reset itself after sleep/wake).
        if owned[fan], let last = lastRPM[fan], abs(last - rpm) <= tolerance,
           smc.readNumber("F\(fan)Md") == 1,
           let target = smc.readNumber("F\(fan)Tg"), abs(target - last) < 1 {
            return
        }
        owned[fan] = true
        try writer.setManual(fan: fan, rpm: rpm) { [self] in
            applying.map { isWanted($0, for: fan) } ?? true
        }
        lastRPM[fan] = rpm
    }

    private func release(_ fan: Int) {
        let released = writer.setAuto(fan: fan)
        owned[fan] = false
        lastRPM[fan] = nil
        smoothedTemp[fan] = [:]
        if !owned.contains(true) {
            writer.endUnlock()
        } else if !released {
            // The SMC would not release just this fan. Hand every fan back to the system, and forget what
            // was written to the fans still under custom control so the next pass takes them over again.
            log("fan \(fan): SMC refused the single-fan release; resetting fan control")
            writer.endUnlock()
            for other in 0..<fanCount where owned[other] {
                lastRPM[other] = nil
            }
        }
    }

    private func limits(of fan: Int) throws -> ClosedRange<Double> {
        guard let minimum = smc.readNumber("F\(fan)Mn"), let maximum = smc.readNumber("F\(fan)Mx"),
              maximum > minimum
        else { throw HelperError(description: "Could not read the RPM limits") }
        return minimum...maximum
    }
}

final class Server {
    private let controller: Controller
    private let allowedUID: uid_t

    init(controller: Controller, allowedUID: uid_t) {
        self.controller = controller
        self.allowedUID = allowedUID
    }

    func run() {
        unlink(HelperSocket.path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0, HelperSocket.withAddress({ bind(listener, $0, $1) }) == 0 else {
            log("could not create socket \(HelperSocket.path): \(String(cString: strerror(errno)))")
            exit(1)
        }
        // Anyone can connect, but only root and allowedUID are served (checked in handle).
        chmod(HelperSocket.path, 0o666)
        listen(listener, 8)

        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global().async {
                self.handle(client)
                close(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        HelperSocket.setTimeout(client, seconds: 2)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == 0 || uid == allowedUID else {
            reply(client, HelperResponse(ok: false, error: "This user is not allowed to control the fans"))
            return
        }
        guard let line = HelperSocket.readLine(client),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: line)
        else {
            reply(client, HelperResponse(ok: false, error: "Invalid request"))
            return
        }

        if request.command == .set {
            guard let fan = request.fan, let mode = request.mode else {
                reply(client, HelperResponse(ok: false, error: "Missing fan or mode"))
                return
            }
            do {
                try controller.set(fan: fan, mode: mode)
                log("fan \(fan) -> \(mode)")
            } catch {
                reply(client, HelperResponse(ok: false, error: "\(error)"))
                return
            }
        }
        let state = controller.snapshot()
        reply(client, HelperResponse(ok: true, modes: state.modes, errors: state.errors))
    }

    private func reply(_ client: Int32, _ response: HelperResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        _ = HelperSocket.writeLine(client, data)
    }
}

// MARK: - Startup

guard geteuid() == 0 else {
    fputs("fancontrold must run as root (install it with scripts/install-helper.sh)\n", stderr)
    exit(1)
}

var allowedUID: uid_t = 0
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--uid"), index + 1 < arguments.count, let uid = uid_t(arguments[index + 1]) {
    allowedUID = uid
}

let controller: Controller
do {
    controller = Controller(smc: try SMC())
} catch {
    log("\(error)")
    exit(1)
}
log("started: \(controller.fanCount) fans, allowed uid \(allowedUID)")

signal(SIGPIPE, SIG_IGN)
// When stopped (uninstall, shutdown) the fans must go back to automatic.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        log("received signal \(number), returning fans to automatic")
        controller.releaseAll()
        unlink(HelperSocket.path)
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

Thread.detachNewThread { controller.run() }
Server(controller: controller, allowedUID: allowedUID).run()
