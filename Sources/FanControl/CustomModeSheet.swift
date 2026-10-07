import SMCKit
import SwiftUI

/// The "Custom" dialog: a fixed speed per fan, or RPM curves driven by CPU and GPU temperature.
struct CustomModeSheet: View {
    private enum Kind {
        case constant
        case curve
    }

    let fan: Fan
    /// Every fan on the machine; the fixed-speed tab has one field for each.
    let fans: [Fan]
    let sensors: [SensorReading]
    /// The mode to set for each fan, keyed by fan id.
    let onApply: ([Int: FanControlMode]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind
    /// Text typed into each fan's fixed-speed field, keyed by fan id.
    @State private var speedText: [Int: String]
    @State private var cpuPoints: [CurvePoint]
    @State private var gpuPoints: [CurvePoint]
    // By default one edit applies to every fan, so nothing has to be set up twice.
    @AppStorage(CustomModeSheet.applyToAllKey) private var applyToAll = true

    private static let applyToAllKey = "applyToAllFans"
    private static let sharedCurvesKey = "curves.shared"
    private static let fixedSpeedsKey = "fixedSpeeds"
    private static let cpuSensor = "cpu.avg"
    private static let gpuSensor = "gpu.avg"
    private static let chartHeight: CGFloat = 210
    // Default shape: off up to 60°C, then a gradual ramp; RPM is a fraction of the fan's maximum.
    private static let defaultShape: [(temp: Double, fraction: Double)] = [
        (20, 0), (60, 0), (68, 0.45), (72, 0.52), (76, 0.6), (80, 0.7), (84, 0.8), (98, 0.9),
    ]

    init(fan: Fan, fans: [Fan], sensors: [SensorReading], modes: [Int: FanControlMode],
         onApply: @escaping ([Int: FanControlMode]) -> Void) {
        self.fan = fan
        self.fans = fans
        self.sensors = sensors
        self.onApply = onApply

        var kind = Kind.curve
        // The running curve, else the last saved one, else the default.
        var curves = Self.savedCurves(for: fan)
        switch modes[fan.id] ?? .auto {
        case .constant:
            kind = .constant
        case .curve(let active):
            curves = active
        case .auto, .sensor:
            break
        }
        // Each field starts at the fan's running fixed speed, else the last one applied, else its minimum.
        let savedSpeeds = UserDefaults.standard.dictionary(forKey: Self.fixedSpeedsKey) as? [String: Int] ?? [:]
        var speedText: [Int: String] = [:]
        for other in fans {
            if case .constant(let rpm) = modes[other.id] ?? .auto {
                speedText[other.id] = String(rpm)
            } else {
                speedText[other.id] = String(savedSpeeds[String(other.id)] ?? Int(other.minRPM))
            }
        }
        func points(_ sensorID: String) -> [CurvePoint] {
            curves.first { $0.sensorID == sensorID }?.points ?? Self.defaultPoints(for: fan)
        }
        _kind = State(initialValue: kind)
        _speedText = State(initialValue: speedText)
        _cpuPoints = State(initialValue: points(Self.cpuSensor))
        _gpuPoints = State(initialValue: points(Self.gpuSensor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The fixed-speed tab covers every fan; a curve names the fan only when it applies to just that one.
            Text(kind == .curve && !applyToAll ? "Custom control: \(fan.name.lowercased())" : "Custom fan control")
                .font(.headline)

            Picker("", selection: $kind) {
                Text("Fixed speed").tag(Kind.constant)
                Text("Temperature curve").tag(Kind.curve)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if kind == .constant {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(fans) { other in
                        GridRow {
                            Text(other.name)
                            TextField("", text: speedBinding(for: other))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 90)
                            Text("RPM")
                            // The allowed range comes from the fan itself: above 0, up to its maximum.
                            Text("1 – \(Int(other.maxRPM))")
                                .font(.caption)
                                .foregroundStyle(speed(for: other) == nil ? Color.red : Color.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } else {
                CurveEditor(title: "CPU, RPM/°C", color: Color(red: 0.36, green: 0.68, blue: 0.93),
                            maxRPM: fan.maxRPM,
                            currentTemp: temperature(Self.cpuSensor), points: $cpuPoints)
                    .frame(height: Self.chartHeight)
                CurveEditor(title: "GPU, RPM/°C", color: Color(red: 0.93, green: 0.26, blue: 0.24),
                            maxRPM: fan.maxRPM,
                            currentTemp: temperature(Self.gpuSensor), points: $gpuPoints)
                    .frame(height: Self.chartHeight)
            }

            HStack {
                if kind == .curve {
                    Button("Reset to Default") {
                        cpuPoints = Self.defaultPoints(for: fan)
                        gpuPoints = Self.defaultPoints(for: fan)
                    }
                }
                // Fixed speed has a field per fan, so the toggle only matters for curves.
                if kind == .curve {
                    Toggle("Apply to all fans", isOn: $applyToAll)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let modes = selectedModes else { return }
                    if kind == .curve {
                        Self.save(curves, for: fan, shared: applyToAll)
                    } else {
                        Self.saveFixedSpeeds(modes)
                    }
                    onApply(modes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedModes == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var curves: [FanCurve] {
        [FanCurve(sensorID: Self.cpuSensor, points: cpuPoints), FanCurve(sensorID: Self.gpuSensor, points: gpuPoints)]
    }

    /// The mode for each fan, or nil while a fixed-speed field holds an invalid value.
    private var selectedModes: [Int: FanControlMode]? {
        switch kind {
        case .constant:
            var modes: [Int: FanControlMode] = [:]
            for other in fans {
                guard let rpm = speed(for: other) else { return nil }
                modes[other.id] = .constant(rpm: rpm)
            }
            return modes
        case .curve:
            let targets = applyToAll ? fans : [fan]
            return Dictionary(uniqueKeysWithValues: targets.map { ($0.id, FanControlMode.curve(curves: curves)) })
        }
    }

    /// The typed speed for a fan if it is a whole number above 0 and no higher than the fan's maximum.
    private func speed(for fan: Fan) -> Int? {
        guard let rpm = Int(speedText[fan.id] ?? ""), rpm > 0, Double(rpm) <= fan.maxRPM else { return nil }
        return rpm
    }

    private func speedBinding(for fan: Fan) -> Binding<String> {
        Binding(get: { speedText[fan.id] ?? "" },
                set: { speedText[fan.id] = $0.filter(\.isNumber) })
    }

    private func temperature(_ sensorID: String) -> Double? {
        sensors.first { $0.id == sensorID }?.celsius
    }

    // MARK: - Defaults and storage

    private static func defaultPoints(for fan: Fan) -> [CurvePoint] {
        defaultShape.map { shape in
            let rpm = shape.fraction == 0 ? 0 : max(fan.minRPM, (shape.fraction * fan.maxRPM / 100).rounded() * 100)
            return CurvePoint(temp: shape.temp, rpm: rpm)
        }
    }

    private static func saveFixedSpeeds(_ modes: [Int: FanControlMode]) {
        var speeds: [String: Int] = [:]
        for (fanID, mode) in modes {
            if case .constant(let rpm) = mode { speeds[String(fanID)] = rpm }
        }
        UserDefaults.standard.set(speeds, forKey: fixedSpeedsKey)
    }

    private static func storageKey(for fan: Fan) -> String {
        "curves.fan\(fan.id)"
    }

    /// Saved curves: the shared set when applying to every fan, the fan's own set otherwise;
    /// falls back to the other one when the preferred set is missing.
    private static func savedCurves(for fan: Fan) -> [FanCurve] {
        let defaults = UserDefaults.standard
        let applyToAll = defaults.object(forKey: applyToAllKey) as? Bool ?? true
        let keys = applyToAll ? [sharedCurvesKey, storageKey(for: fan)] : [storageKey(for: fan), sharedCurvesKey]
        for key in keys {
            if let data = defaults.data(forKey: key), let curves = try? JSONDecoder().decode([FanCurve].self, from: data) {
                return curves
            }
        }
        return []
    }

    private static func save(_ curves: [FanCurve], for fan: Fan, shared: Bool) {
        guard let data = try? JSONEncoder().encode(curves) else { return }
        UserDefaults.standard.set(data, forKey: shared ? sharedCurvesKey : storageKey(for: fan))
    }
}
