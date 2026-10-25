import AppKit
import Foundation
import SMCKit

enum HelperState: Equatable {
    case checking
    case connected
    case outdated
    case unavailable

    var canControl: Bool { self == .connected }
}

enum FanPreset {
    case medium
    case turbo

    /// Share of each fan's maximum speed.
    var fraction: Double {
        switch self {
        case .medium: return 0.5
        case .turbo: return 1
        }
    }
}

final class AppModel: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var sensors: [SensorReading] = []
    @Published var sensorGroups: [SensorGroup] = []
    @Published var modes: [FanControlMode] = []
    @Published var fanErrors: [String?] = []
    @Published var helperState: HelperState = .checking
    @Published var message: String?
    @Published var installing = false

    /// True while the helper is forcing at least one fan (fixed speed or curve).
    var isControlling: Bool {
        modes.contains { $0 != .auto }
    }

    /// The preset running every fan at a share of its maximum (Medium or Turbo), if one is on.
    @Published private(set) var preset: FanPreset?
    /// While a preset is on: the mode each fan had before, keyed by fan id, to go back to when it is switched off.
    private var modesBeforePreset: [Int: FanControlMode] = [:]

    var isTurbo: Bool {
        preset == .turbo
    }

    // All SMC and socket work runs on this queue so it never blocks the UI.
    private let queue = DispatchQueue(label: "local.fancontrol.poll")
    private var smc: SMC?
    private var catalog: SensorCatalog?
    private var timer: Timer?

    private static let refreshInterval: TimeInterval = 2
    private static let savedModesKey = "savedModes"
    private static let lastCustomModesKey = "lastCustomModes"
    private var restoredSavedModes = false
    /// Modes the user just picked that the helper has not acknowledged yet, keyed by fan id.
    private var pendingModes: [Int: FanControlMode] = [:]

    init() {
        queue.async { [weak self] in
            do {
                let smc = try SMC()
                self?.smc = smc
                self?.catalog = SensorCatalog(smc: smc)
            } catch {
                DispatchQueue.main.async { self?.message = "\(error)" }
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func mode(of fan: Fan) -> FanControlMode {
        fan.id < modes.count ? modes[fan.id] : .auto
    }

    func error(of fan: Fan) -> String? {
        fan.id < fanErrors.count ? fanErrors[fan.id] : nil
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let fans = self.smc?.fans() ?? []
            let sensors = self.catalog?.readSummary() ?? []
            let sensorGroups = self.catalog?.readGroups() ?? []
            let helper = try? HelperClient.send(.status)
            DispatchQueue.main.async {
                self.fans = fans
                self.sensors = sensors
                self.sensorGroups = self.fillingGaps(in: sensorGroups)
                self.apply(helper)
            }
        }
    }

    /// Sets the mode the user picked for a fan and remembers it so the next launch restores it.
    func setMode(_ mode: FanControlMode, for fan: Fan) {
        // Picking a mode ends the preset: the other fans go back to what they had before it.
        if preset != nil {
            preset = nil
            for other in fans where other.id != fan.id {
                show(modesBeforePreset[other.id] ?? .auto, forFan: other.id)
            }
        }
        Self.remember(mode, forFan: fan.id, key: Self.savedModesKey)
        if mode != .auto { Self.remember(mode, forFan: fan.id, key: Self.lastCustomModesKey) }
        show(mode, forFan: fan.id)
    }

    func toggleTurbo() {
        toggle(.turbo)
    }

    /// A preset runs every fan at its share of the maximum right away; switching it off returns each fan to its
    /// previous mode. Switching from one preset to the other keeps the modes from before the first one.
    /// It is deliberately not remembered: quitting, or the next launch, goes back to the saved modes.
    func toggle(_ preset: FanPreset) {
        if self.preset == preset {
            self.preset = nil
            for fan in fans {
                show(modesBeforePreset[fan.id] ?? .auto, forFan: fan.id)
            }
            return
        }
        if self.preset == nil {
            modesBeforePreset = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, mode(of: $0)) })
        }
        self.preset = preset
        for fan in fans {
            // Never ask for less than the fan's minimum, which some fans keep above half their maximum.
            let rpm = max(fan.maxRPM * preset.fraction, fan.minRPM)
            show(.constant(rpm: Int(rpm)), forFan: fan.id)
        }
    }

    /// Shows a mode right away and keeps showing it until the helper has taken the request;
    /// the actual switch carries on underneath and may take a few seconds.
    private func show(_ mode: FanControlMode, forFan fanID: Int) {
        pendingModes[fanID] = mode
        if modes.indices.contains(fanID) { modes[fanID] = mode }
        send(mode, toFan: fanID)
    }

    /// The custom mode this fan last used, so Custom can switch back to it without opening the dialog.
    func lastCustomMode(for fan: Fan) -> FanControlMode? {
        let key = String(fan.id)
        if let mode = Self.savedModes(key: Self.lastCustomModesKey)[key] { return mode }
        if let mode = Self.savedModes()[key], mode != .auto { return mode }
        return nil
    }

    private static func remember(_ mode: FanControlMode, forFan fanID: Int, key: String) {
        var saved = savedModes(key: key)
        saved[String(fanID)] = mode
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func send(_ mode: FanControlMode, toFan fanID: Int) {
        queue.async { [weak self] in
            do {
                let response = try HelperClient.send(.set(fan: fanID, mode: mode))
                DispatchQueue.main.async {
                    self?.message = nil
                    if self?.pendingModes[fanID] == mode { self?.pendingModes[fanID] = nil }
                    self?.apply(response)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.pendingModes[fanID] = nil
                    self?.message = "\(error)"
                }
            }
        }
    }

    /// Returns every fan to automatic and waits for it; used when the app quits.
    func releaseAllFans() {
        queue.sync {
            for index in modes.indices where modes[index] != .auto {
                _ = try? HelperClient.send(.set(fan: index, mode: .auto))
            }
        }
    }

    /// Installs (or updates) the root helper; macOS asks for an administrator password.
    func installHelper() {
        guard let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("install-helper.sh").path
        let helper = resources.appendingPathComponent("fancontrold").path
        guard FileManager.default.fileExists(atPath: script), FileManager.default.fileExists(atPath: helper) else {
            message = "Helper not found in the app bundle. Build with scripts/build.sh."
            return
        }

        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \"/bin/bash \" & quoted form of \(quoted(script)) & \" \" & "
            + "quoted form of \(quoted(helper)) & \" \(getuid())\" "
            + "with prompt \"Fan Control needs to install its helper to control the fans.\" with administrator privileges"

        installing = true
        message = nil
        DispatchQueue.global().async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()
            var failure: String?
            do {
                try process.run()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let output = String(data: errorData, encoding: .utf8) ?? ""
                    // -128: the user pressed Cancel in the password dialog.
                    failure = output.contains("-128") ? nil : "Helper installation failed: \(output)"
                }
            } catch {
                failure = "Helper installation failed: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self?.installing = false
                self?.message = failure
                self?.refresh()
            }
        }
    }

    /// When a pass has no reading (NaN), keeps the latest one so the number does not flicker to "—".
    private func fillingGaps(in groups: [SensorGroup]) -> [SensorGroup] {
        groups.map { group in
            let previous = sensorGroups.first { $0.id == group.id }
            let members = group.members.map { member -> SensorReading in
                guard member.celsius.isNaN,
                      let last = previous?.members.first(where: { $0.id == member.id }) else { return member }
                return last
            }
            let average = group.average.isNaN ? (previous?.average ?? .nan) : group.average
            return SensorGroup(id: group.id, name: group.name, average: average, members: members)
        }
    }

    private func apply(_ helper: HelperResponse?) {
        guard let helper else {
            helperState = .unavailable
            modes = []
            fanErrors = []
            return
        }
        helperState = helper.version == HelperSocket.protocolVersion ? .connected : .outdated
        // A status reply fetched just before a click must not flip the buttons back.
        var shown = helper.modes
        for (fanID, mode) in pendingModes where shown.indices.contains(fanID) {
            shown[fanID] = mode
        }
        modes = shown
        fanErrors = helper.errors
        if helperState == .connected, !restoredSavedModes {
            restoredSavedModes = true
            restoreSavedModes(current: helper.modes)
        }
    }

    /// Quitting returns the fans to automatic; the next launch reapplies the saved mode to fans still on automatic.
    private func restoreSavedModes(current: [FanControlMode]) {
        for (key, mode) in Self.savedModes() where mode != .auto {
            guard let fanID = Int(key), current.indices.contains(fanID), current[fanID] == .auto else { continue }
            send(mode, toFan: fanID)
        }
    }

    private static func savedModes(key: String = savedModesKey) -> [String: FanControlMode] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let modes = try? JSONDecoder().decode([String: FanControlMode].self, from: data)
        else { return [:] }
        return modes
    }
}
