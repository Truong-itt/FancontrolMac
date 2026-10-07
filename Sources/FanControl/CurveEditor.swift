import SMCKit
import SwiftUI

/// RPM/°C chart with draggable points. The vertical axis starts at OFF (fan stopped).
struct CurveEditor: View {
    /// A drag in progress, identified by where it started.
    private struct ActiveDrag: Equatable {
        let start: CGPoint
        /// The point being dragged; nil when the drag started on empty space.
        let index: Int?
        /// Offset between the cursor and the point's centre at the start, so the dot does not jump to the cursor.
        let offset: CGSize
    }

    let title: String
    let color: Color
    let maxRPM: Double
    /// The sensor's current temperature, drawn as a vertical line to show where on the curve we are.
    let currentTemp: Double?
    @Binding var points: [CurvePoint]

    @State private var drag: ActiveDrag?

    static let tempRange = 10.0...100.0
    private static let rpmStep = 10.0
    private static let gridRPMStep = 1000.0
    private static let pointRadius: CGFloat = 7
    // A press within this distance of a point grabs it; no need to hit the dot exactly.
    private static let grabRadius: CGFloat = 18
    private static let insets = EdgeInsets(top: 10, leading: 46, bottom: 28, trailing: 14)
    private static let background = Color(red: 0.13, green: 0.13, blue: 0.14)

    var body: some View {
        VStack(spacing: 4) {
            Text(headline)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
            GeometryReader { geometry in
                let plot = plotRect(in: geometry.size)
                ZStack {
                    Canvas { context, _ in drawGrid(in: &context, plot: plot) }
                    curvePath(in: plot).stroke(color, lineWidth: 1.5)
                    if let currentTemp, Self.tempRange.contains(currentTemp) {
                        Path { path in
                            path.move(to: CGPoint(x: x(currentTemp, plot), y: plot.minY))
                            path.addLine(to: CGPoint(x: x(currentTemp, plot), y: plot.maxY))
                        }
                        .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(points.indices, id: \.self) { index in
                        let active = movingIndex == index
                        Circle()
                            .fill(color)
                            .overlay(Circle().stroke(.white, lineWidth: active ? 2 : 0))
                            .frame(width: Self.pointRadius * 2, height: Self.pointRadius * 2)
                            .scaleEffect(active ? 1.3 : 1)
                            .position(position(of: points[index], plot))
                    }
                    .allowsHitTesting(false)
                }
                // The whole chart takes the mouse: drag moves the nearest point, double-click adds or removes one.
                .contentShape(Rectangle())
                .gesture(dragGesture(plot: plot))
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { toggle(at: $0.location, plot: plot) }
                )
            }
        }
        .padding(8)
        .background(Self.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var movingIndex: Int? {
        drag?.index
    }

    /// The title; while dragging it shows the value of the point being dragged.
    private var headline: String {
        guard let index = movingIndex, points.indices.contains(index) else { return title }
        let point = points[index]
        let rpm = tidied(point).rpm
        return "\(Int(point.temp.rounded()))°C → " + (rpm == 0 ? "OFF" : "\(Int(rpm)) RPM")
    }

    // MARK: - Coordinates

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: Self.insets.leading, y: Self.insets.top,
               width: max(1, size.width - Self.insets.leading - Self.insets.trailing),
               height: max(1, size.height - Self.insets.top - Self.insets.bottom))
    }

    private func x(_ temp: Double, _ plot: CGRect) -> CGFloat {
        let range = Self.tempRange
        return plot.minX + (temp - range.lowerBound) / (range.upperBound - range.lowerBound) * plot.width
    }

    private func y(_ rpm: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - rpm / maxRPM * plot.height
    }

    private func position(of point: CurvePoint, _ plot: CGRect) -> CGPoint {
        CGPoint(x: x(point.temp, plot), y: y(point.rpm, plot))
    }

    private func temp(atX position: CGFloat, plot: CGRect) -> Double {
        let range = Self.tempRange
        let raw = range.lowerBound + (position - plot.minX) / plot.width * (range.upperBound - range.lowerBound)
        return max(range.lowerBound, min(range.upperBound, raw))
    }

    private func rpm(atY position: CGFloat, plot: CGRect) -> Double {
        max(0, min(maxRPM, (plot.maxY - position) / plot.height * maxRPM))
    }

    /// Value stored on release: rounded so slightly (10 RPM, 0.1°C) that the dot does not visibly move.
    private func tidied(_ point: CurvePoint) -> CurvePoint {
        CurvePoint(temp: (point.temp * 10).rounded() / 10, rpm: (point.rpm / Self.rpmStep).rounded() * Self.rpmStep)
    }

    private func nearestPoint(to location: CGPoint, plot: CGRect) -> Int? {
        let distances = points.map { point -> CGFloat in
            let position = self.position(of: point, plot)
            return hypot(position.x - location.x, position.y - location.y)
        }
        guard let index = distances.indices.min(by: { distances[$0] < distances[$1] }),
              distances[index] <= Self.grabRadius
        else { return nil }
        return index
    }

    // MARK: - Editing

    private func dragGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Pick the point once per drag and stay on it until release. A new drag is recognised by its start
                // location, so stale state left by a cancelled gesture cannot get in the way.
                var active = drag
                if active?.start != value.startLocation {
                    let index = nearestPoint(to: value.startLocation, plot: plot)
                    let origin = index.map { position(of: points[$0], plot) } ?? value.startLocation
                    active = ActiveDrag(start: value.startLocation, index: index,
                                        offset: CGSize(width: origin.x - value.startLocation.x,
                                                       height: origin.y - value.startLocation.y))
                    drag = active
                }
                guard let active, let index = active.index, points.indices.contains(index) else { return }
                let target = CGPoint(x: value.location.x + active.offset.width,
                                     y: value.location.y + active.offset.height)
                // Keep points ordered by temperature: a point cannot pass its neighbours.
                let lower = index > 0 ? points[index - 1].temp + 1 : Self.tempRange.lowerBound
                let upper = index < points.count - 1 ? points[index + 1].temp - 1 : Self.tempRange.upperBound
                guard lower <= upper else { return }
                // The dot follows the cursor freely; dragging down to the axis means OFF (0 RPM).
                points[index].temp = max(lower, min(upper, temp(atX: target.x, plot: plot)))
                points[index].rpm = rpm(atY: target.y, plot: plot)
            }
            .onEnded { _ in
                drag = nil
                // Tidy the numbers after release; the change is too small for the dots to visibly move.
                points = points.map(tidied)
            }
    }

    /// Double-clicking a point removes it; double-clicking empty space adds a new one.
    private func toggle(at location: CGPoint, plot: CGRect) {
        if let index = nearestPoint(to: location, plot: plot) {
            if points.count > 2 { points.remove(at: index) }
            return
        }
        let newTemp = temp(atX: location.x, plot: plot).rounded()
        guard !points.contains(where: { abs($0.temp - newTemp) < 1 }) else { return }
        points.append(tidied(CurvePoint(temp: newTemp, rpm: rpm(atY: location.y, plot: plot))))
        points.sort { $0.temp < $1.temp }
    }

    // MARK: - Drawing

    private func curvePath(in plot: CGRect) -> Path {
        Path { path in
            for (index, point) in points.enumerated() {
                let position = self.position(of: point, plot)
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
        }
    }

    private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
        let gridColor = Color.white.opacity(0.12)
        let labelColor = Color.white.opacity(0.8)
        let font = Font.system(size: 10)

        for rpm in stride(from: 0.0, through: maxRPM, by: Self.gridRPMStep) {
            let position = y(rpm, plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: position))
            line.addLine(to: CGPoint(x: plot.maxX, y: position))
            context.stroke(line, with: .color(gridColor), lineWidth: 1)
            let label = Text(rpm == 0 ? "OFF" : "\(Int(rpm))").font(font).foregroundColor(labelColor)
            context.draw(label, at: CGPoint(x: plot.minX - 6, y: position), anchor: .trailing)
        }
        for temp in stride(from: Self.tempRange.lowerBound, through: Self.tempRange.upperBound, by: 10) {
            let position = x(temp, plot)
            var line = Path()
            line.move(to: CGPoint(x: position, y: plot.minY))
            line.addLine(to: CGPoint(x: position, y: plot.maxY))
            context.stroke(line, with: .color(gridColor), lineWidth: 1)
            let label = Text("\(Int(temp))").font(font).foregroundColor(labelColor)
            // Sits below the dot radius so a point at OFF does not cover the label.
            context.draw(label, at: CGPoint(x: position, y: plot.maxY + Self.pointRadius + 4), anchor: .top)
        }
    }
}
