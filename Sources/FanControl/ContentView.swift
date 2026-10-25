import SMCKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingFan: Fan?
    // Only CPU and GPU (the hottest parts) show by default; the other sensors are opt-in.
    @AppStorage("showOtherSensors") private var showOtherSensors = false
    @State private var sensorContentHeight: CGFloat = 0

    // Just wide enough for the two mode buttons, so they sit flush with the right edge like the temperatures below.
    fileprivate static let controlColumnWidth: CGFloat = 132
    fileprivate static let nameColumnWidth: CGFloat = 118
    // A sensor list taller than this scrolls instead of growing the window.
    private static let maxSensorListHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                fanTable
                sensorTable
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 12)
            // The status bar only appears when something needs attention.
            if needsAttention {
                Divider()
                statusBar
            }
        }
        // Height follows the content: the window resizes as sensor groups open and close.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 372)
        .sheet(item: $editingFan) { fan in
            let modes = Dictionary(uniqueKeysWithValues: model.fans.map { ($0.id, model.mode(of: $0)) })
            CustomModeSheet(fan: fan, fans: model.fans, sensors: model.sensors, modes: modes) { chosen in
                for target in model.fans {
                    if let mode = chosen[target.id] { model.setMode(mode, for: target) }
                }
            }
            // Each fan gets its own dialog state instead of reusing another fan's selection.
            .id(fan.id)
        }
    }

    // MARK: - Fans

    private var fanTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fan").frame(width: Self.nameColumnWidth, alignment: .leading)
                Text("Speed").frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    presetButton(.medium, title: "Medium", icon: "gauge.medium", tint: .blue, help: "Run all fans at 50%")
                    presetButton(.turbo, title: "Turbo", icon: "bolt.fill", tint: .orange, help: "Run all fans at 100%")
                }
                .controlSize(.small)
                .disabled(!model.helperState.canControl || model.fans.isEmpty)
                .fixedSize()
                .frame(width: Self.controlColumnWidth, alignment: .trailing)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if model.fans.isEmpty {
                Text("No fans found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
            } else {
                ForEach(model.fans) { fan in
                    FanRow(fan: fan, mode: model.mode(of: fan), error: model.error(of: fan),
                           canControl: model.helperState.canControl, presetOn: model.preset != nil,
                           onAuto: { model.setMode(.auto, for: fan) },
                           onCustom: { chooseCustom(for: fan) })
                    // Separator between rows only; the table border closes the last one.
                    if fan.id != model.fans.last?.id { Divider() }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
    }

    /// Runs every fan at the preset's speed while on; pressing it again goes back to the previous modes.
    @ViewBuilder
    private func presetButton(_ preset: FanPreset, title: String, icon: String, tint: Color,
                              help: String) -> some View {
        let label = Label(title, systemImage: icon)
        Group {
            if model.preset == preset {
                Button { model.toggle(preset) } label: { label }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            } else {
                Button { model.toggle(preset) } label: { label }
                    .buttonStyle(.bordered)
            }
        }
        .help(help)
    }

    /// Custom on a fan that is on auto switches straight back to its last custom mode; pressing it
    /// again (or with nothing remembered yet) opens the dialog to edit.
    private func chooseCustom(for fan: Fan) {
        if model.preset != nil || model.mode(of: fan) == .auto, let last = model.lastCustomMode(for: fan) {
            model.setMode(last, for: fan)
        } else {
            editingFan = fan
        }
    }

    // MARK: - Sensors

    private var sensorTable: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.sensorGroups) { SensorGroupView(group: $0) }
                    if showOtherSensors {
                        ForEach(otherSensors) { SensorRow(reading: $0) }
                    }
                }
                .padding(.vertical, 4)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SensorHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(height: min(sensorContentHeight, Self.maxSensorListHeight))
            .onPreferenceChange(SensorHeightKey.self) { sensorContentHeight = $0 }
            Divider()
            Toggle("Show other sensors (battery, SSD, Wi-Fi…)", isOn: $showOtherSensors)
                .toggleStyle(.checkbox)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
    }

    /// Sensors other than CPU/GPU (battery, SSD, Wi-Fi…); CPU and GPU already live in the groups.
    private var otherSensors: [SensorReading] {
        model.sensors.filter { !$0.id.hasPrefix("cpu.") && !$0.id.hasPrefix("gpu.") }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            switch model.helperState {
            case .checking, .connected:
                EmptyView()
            case .outdated:
                Label("Installed helper is outdated", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                installButton(title: "Update Helper…")
            case .unavailable:
                Label("Read-only: helper not installed", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
                installButton(title: "Install Helper…")
            }
            if let message = model.message {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// True when the helper is missing or outdated, or there is an error to report.
    private var needsAttention: Bool {
        model.helperState == .outdated || model.helperState == .unavailable || model.message != nil
    }

    private func installButton(title: String) -> some View {
        Button(title) { model.installHelper() }
            .disabled(model.installing)
    }
}

private struct FanRow: View {
    let fan: Fan
    let mode: FanControlMode
    let error: String?
    let canControl: Bool
    /// While Medium or Turbo is on neither mode button is highlighted; the preset button is.
    let presetOn: Bool
    let onAuto: () -> Void
    let onCustom: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "fan")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(fan.name).font(.title3)
            }
            .frame(width: ContentView.nameColumnWidth, alignment: .leading)

            VStack(spacing: 2) {
                Text("\(Int(fan.actualRPM))")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                // A note appears only when there is something to know: an error, or another program driving the fan.
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                modeButton("Auto", active: !presetOn && mode == .auto, action: onAuto)
                modeButton("Custom", active: !presetOn && mode != .auto, action: onCustom)
            }
            .disabled(!canControl)
            .fixedSize()
            .frame(width: ContentView.controlColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var notice: String? {
        if let error { return error }
        return mode == .auto && fan.manual ? "Controlled by another app" : nil
    }

    @ViewBuilder
    private func modeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        if active {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
        }
    }
}

private struct SensorHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TemperatureText: View {
    let celsius: Double

    var body: some View {
        // NaN: the sensor has no reading right now (that part of the chip is powered down).
        Text(celsius.isNaN ? "—" : "\(Int(celsius.rounded()))")
            .monospacedDigit()
            .foregroundStyle(celsius >= 90 ? Color.red : Color.primary)
    }
}

private struct SensorRow: View {
    let reading: SensorReading
    var indented = false

    var body: some View {
        HStack {
            Text(reading.name)
            Text(reading.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TemperatureText(celsius: reading.celsius)
        }
        .padding(.leading, indented ? 28 : 10)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
    }
}

/// A collapsible group: the outer row shows the average, expanding reveals the detail rows.
private struct SensorGroupView: View {
    let group: SensorGroup
    @AppStorage private var expanded: Bool

    init(group: SensorGroup) {
        self.group = group
        _expanded = AppStorage(wrappedValue: false, "expanded.\(group.id)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text(group.name).fontWeight(.medium)
                    Text("average")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TemperatureText(celsius: group.average)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(group.members) { SensorRow(reading: $0, indented: true) }
            }
        }
    }
}
