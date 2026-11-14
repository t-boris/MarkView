import SwiftUI

/// The instrument panel of the run screen (DEC-028, REQ-009): dials, a trip readout, a pulse trace and the annunciator lamps. Every
/// reading comes from `CockpitReadings`, which computes real values of the run; this file only draws them.
///
/// The panel is a dark instrument glass in both themes (a cockpit does not turn white); the warning colours come from the window's palette.
enum CockpitGlass {
    static let bezel = Color(red: 0.055, green: 0.063, blue: 0.082)
    static let bezelEdge = Color(red: 0.13, green: 0.145, blue: 0.18)
    static let face = Color(red: 0.095, green: 0.105, blue: 0.135)
    static let line = Color.white.opacity(0.16)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.55)
}

// MARK: Shapes

/// A stretch of a dial's scale. The scale sweeps 270 degrees, from the lower left over the top to the lower right.
private struct DialArc: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // SwiftUI's `clockwise` is inverted on screen: false draws in the direction of growing angles, which is clockwise.
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(135 + 270 * from), endAngle: .degrees(135 + 270 * to), clockwise: false)
        return path
    }
}

private struct DialNeedle: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let angle = Angle.degrees(135 + 270 * min(1, max(0, fraction))).radians
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * radius * 0.9, y: center.y + CGFloat(sin(angle)) * radius * 0.9))
        return path
    }
}

private struct DialTicks: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for tick in 0...10 {
            let angle = Angle.degrees(135 + 27 * Double(tick)).radians
            let inner = radius * (tick % 5 == 0 ? 0.84 : 0.9)
            path.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * inner, y: center.y + CGFloat(sin(angle)) * inner))
            path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius))
        }
        return path
    }
}

// MARK: Dial

/// A round gauge: a scale with coloured stretches, a needle that moves when the value does, and a readout.
struct CockpitDial: View {
    let title: String
    let readout: String
    let caption: String
    /// The needle's place, 0...1. nil draws no needle: the quantity has no limit to measure against.
    let fraction: Double?
    /// Coloured stretches of the scale as (from, to, colour), in fractions of the sweep.
    let zones: [(from: Double, to: Double, color: Color)]
    let tint: Color
    /// What the dial measures, in words: its tooltip and its accessibility value's companion.
    let help: String
    let spoken: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title).uiFont(size: 10, weight: .semibold, design: .monospaced).tracking(1.4).foregroundColor(CockpitGlass.dim)
            ZStack {
                Circle().fill(CockpitGlass.face)
                Circle().stroke(CockpitGlass.line, lineWidth: 1)
                DialArc(from: 0, to: 1).stroke(CockpitGlass.line, style: StrokeStyle(lineWidth: 6)).padding(11)
                ForEach(zones.indices, id: \.self) { index in
                    DialArc(from: zones[index].from, to: zones[index].to)
                        .stroke(zones[index].color.opacity(0.9), style: StrokeStyle(lineWidth: 6)).padding(11)
                }
                DialTicks().stroke(CockpitGlass.dim, lineWidth: 1).padding(4)
                if let fraction {
                    DialNeedle(fraction: fraction).stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).padding(11)
                        .animation(.easeInOut(duration: 0.8), value: fraction)
                    Circle().fill(tint).frame(width: 9, height: 9)
                }
                Text(readout).uiFont(size: 14, weight: .semibold, design: .monospaced).foregroundColor(tint)
                    .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: 80).offset(y: 34)
            }
            .frame(width: 128, height: 128)
            Text(caption).uiFont(size: 10).foregroundColor(CockpitGlass.dim).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(width: 140, alignment: .top)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        // The reading is in the label: an element without children carries no separate value for assistive technology or the probe.
        .accessibilityLabel(title.capitalized + ": " + spoken)
        .accessibilityHint(help)
    }
}

// MARK: Trip readout

/// The distance to the destination is not an angle: it is a readout of the steps left and, once a step has passed, the time they take.
struct CockpitTripReadout: View {
    let steps: Int
    let total: Int
    let estimate: Double?
    let finished: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            Text("DISTANCE").uiFont(size: 10, weight: .semibold, design: .monospaced).tracking(1.4).foregroundColor(CockpitGlass.dim)
            VStack(spacing: 4) {
                Text(finished ? "ARRIVED" : "\(steps)").uiFont(size: finished ? 18 : 34, weight: .semibold, design: .monospaced).foregroundColor(tint)
                    .lineLimit(1).minimumScaleFactor(0.4).frame(maxWidth: 112)
                Text(finished ? "every step done" : (steps == 1 ? "step to go" : "steps to go")).uiFont(size: 10).foregroundColor(CockpitGlass.dim)
                Rectangle().fill(CockpitGlass.line).frame(width: 80, height: 1)
                Text(estimateText).uiFont(size: 12, weight: .medium, design: .monospaced).foregroundColor(CockpitGlass.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(width: 128, height: 128)
            .background(RoundedRectangle(cornerRadius: 14).fill(CockpitGlass.face))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(CockpitGlass.line, lineWidth: 1))
            Text(estimate == nil && !finished ? "an estimate appears after the first step" : "estimated from the steps already done")
                .uiFont(size: 10).foregroundColor(CockpitGlass.dim).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(width: 140, alignment: .top)
        }
        .help("Distance to the destination: the steps still to go, and an estimate of the time they take, from how long the steps already done took.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance to destination: " + spoken)
    }

    private var spoken: String {
        if finished { return "Arrived, every step done" }
        var text = "\(steps) of \(total) steps to go"
        if let estimate { text += ", about " + CockpitFormat.duration(estimate) } else { text += ", no estimate yet" }
        return text
    }

    private var estimateText: String {
        if finished { return "—" }
        guard let estimate else { return "no estimate" }
        return "≈ " + CockpitFormat.duration(estimate)
    }
}

// MARK: Pulse

/// The pulse of the running agent: a trace whose beats are strong while the agent shows signs of life and flatten as it goes quiet.
/// The trace scrolls only while the run is going; the strength is the real quiet time.
struct CockpitPulseTrace: View {
    let pulse: CockpitReadings.Pulse
    let animated: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            Text("PULSE").uiFont(size: 10, weight: .semibold, design: .monospaced).tracking(1.4).foregroundColor(CockpitGlass.dim)
            VStack(spacing: 6) {
                if animated {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in trace(phase: context.date.timeIntervalSinceReferenceDate * 0.35) }
                } else {
                    trace(phase: 0)
                }
                Text(readout).uiFont(size: 12, weight: .medium, design: .monospaced).foregroundColor(pulse.band == .idle ? CockpitGlass.dim : tint)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            .padding(10)
            .frame(width: 128, height: 128)
            .background(RoundedRectangle(cornerRadius: 14).fill(CockpitGlass.face))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(CockpitGlass.line, lineWidth: 1))
            Text("time since the agent last showed it was alive").uiFont(size: 10).foregroundColor(CockpitGlass.dim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(width: 140, alignment: .top)
        }
        .help("Pulse: how long the running step's agent has been quiet. The beats flatten as the time grows, and the run is called silent after 20 minutes.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pulse: " + spoken)
    }

    /// 1 for a sign of life just now, 0 at the silence threshold.
    private var strength: Double {
        guard let quiet = pulse.quietSeconds else { return 0 }
        return max(0, 1 - quiet / CockpitRun.silenceThreshold)
    }

    private var readout: String {
        guard let quiet = pulse.quietSeconds else { return "not running" }
        return "quiet " + CockpitFormat.duration(quiet)
    }

    private var spoken: String {
        guard let quiet = pulse.quietSeconds else { return "The run is not going" }
        return "Quiet for " + CockpitFormat.duration(quiet) + (pulse.band == .silent ? ", silent" : "")
    }

    private func trace(phase: Double) -> some View {
        Canvas { context, size in
            let amplitude = pulse.band == .idle ? 0.0 : strength
            let mid = size.height / 2
            var path = Path()
            let samples = 96
            for index in 0...samples {
                let x = Double(index) / Double(samples)
                // One beat per 0.33 of the width, scrolling to the left.
                let t = (x * 3 + phase).truncatingRemainder(dividingBy: 1)
                let y = mid - CGFloat(Self.beat(t) * amplitude) * (size.height * 0.45)
                if index == 0 { path.move(to: CGPoint(x: 0, y: y)) } else { path.addLine(to: CGPoint(x: CGFloat(x) * size.width, y: y)) }
            }
            context.stroke(path, with: .color(pulse.band == .idle ? CockpitGlass.line : tint), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .frame(height: 70)
    }

    /// One heartbeat: a small bump, a spike with a dip, a rounder bump; 0 in between.
    private static func beat(_ t: Double) -> Double {
        func bump(_ centre: Double, _ width: Double, _ height: Double) -> Double { height * exp(-pow((t - centre) / width, 2)) }
        return bump(0.18, 0.045, 0.18) + bump(0.40, 0.012, 1.0) - bump(0.44, 0.014, 0.28) + bump(0.66, 0.06, 0.3)
    }
}

// MARK: Lamps

struct CockpitLamp: View {
    let text: String
    let lit: Bool
    let tint: Color

    var body: some View {
        Text(text).uiFont(size: 9.5, weight: .bold, design: .monospaced).tracking(0.8)
            .foregroundColor(lit ? Color.black.opacity(0.85) : CockpitGlass.dim.opacity(0.7))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(lit ? tint : CockpitGlass.face))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(lit ? tint : CockpitGlass.line, lineWidth: 1))
            .shadow(color: lit ? tint.opacity(0.6) : .clear, radius: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.capitalized + ": " + (lit ? "on" : "off"))
    }
}

// MARK: Panel

struct CockpitInstrumentPanel: View {
    @Environment(\.palette) private var palette
    let readings: CockpitReadings
    /// The run is going now: the pulse moves.
    let live: Bool

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: 10, alignment: .top)], alignment: .center, spacing: 12) {
                altitude
                CockpitTripReadout(steps: readings.distance.stepsLeft, total: readings.distance.total, estimate: readings.distance.estimatedSeconds,
                                   finished: readings.distance.total > 0 && readings.distance.stepsLeft == 0, tint: palette.cyan)
                fuel
                turns
                wind
                CockpitPulseTrace(pulse: readings.pulse, animated: live && readings.pulse.band != .idle, tint: color(for: readings.pulse.band))
            }
            lamps
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [CockpitGlass.bezelEdge, CockpitGlass.bezel], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Instrument panel")
    }

    // MARK: Dials

    private var altitude: some View {
        let a = readings.altitude
        return CockpitDial(title: "ALTITUDE", readout: "\(a.done)/\(a.total)", caption: "steps done", fraction: a.fraction, zones: [(0, a.fraction, palette.cyan)],
                           tint: palette.cyan, help: "Altitude: how far up the plan the run is, the steps that have passed or been skipped out of all steps.",
                           spoken: "\(a.done) of \(a.total) steps done")
    }

    private var fuel: some View {
        let g = readings.fuel
        let limit = g.limit
        return CockpitDial(title: "FUEL", readout: CockpitFormat.duration(g.used),
                           caption: limit.map { "agent time of \(CockpitFormat.duration($0))" } ?? "agent time, no limit",
                           fraction: g.fraction, zones: limit == nil ? [] : Self.limitZones(palette), tint: color(for: g.band),
                           help: "Fuel: the time the agents have worked against the plan's time limit. At the limit the step stops and the run pauses.",
                           spoken: CockpitFormat.duration(g.used) + (limit.map { " of \(CockpitFormat.duration($0))" } ?? ", no limit"))
    }

    private var turns: some View {
        let g = readings.turns
        let used = Int(g.used)
        return CockpitDial(title: "TURNS", readout: g.limit.map { "\(used)/\(Int($0))" } ?? "\(used)",
                           caption: g.limit == nil ? "fix cycles, no limit" : "fix cycles used",
                           fraction: g.fraction, zones: g.limit == nil ? [] : Self.limitZones(palette), tint: color(for: g.band),
                           help: "Turns: how many times the run went back to fix a bug, against the plan's fix cycle limit. At the limit the step stops and the run pauses.",
                           spoken: "\(used) fix cycles" + (g.limit.map { " of \(Int($0))" } ?? ", no limit"))
    }

    private var wind: some View {
        let w = readings.wind
        let parts = [w.refusals > 0 ? "\(w.refusals) refused" : nil, w.failedSteps > 0 ? "\(w.failedSteps) failed" : nil,
                     w.unanswered > 0 ? "\(w.unanswered) unanswered" : nil, w.silent ? "silent" : nil].compactMap { $0 }
        return CockpitDial(title: "WIND", readout: w.band.rawValue.uppercased(), caption: parts.isEmpty ? "no resistance met" : parts.joined(separator: " · "),
                           fraction: min(1, Double(w.score) / 8),
                           zones: [(0, 0.1, palette.green), (0.1, 0.35, palette.yellow), (0.35, 0.7, palette.orange), (0.7, 1, palette.red)],
                           tint: color(for: w.band),
                           help: "Wind: the resistance the run has met. It counts calls the gate refused and questions the supervisor could not answer in the last hour, steps that failed or were interrupted, and silence.",
                           spoken: w.band.rawValue + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")))
    }

    private static func limitZones(_ palette: AppPalette) -> [(from: Double, to: Double, color: Color)] {
        [(0, CockpitReadings.cautionShare, palette.green), (CockpitReadings.cautionShare, 0.97, palette.orange), (0.97, 1, palette.red)]
    }

    // MARK: Colours

    private func color(for band: CockpitReadings.Band) -> Color {
        switch band { case .ok: return palette.green; case .caution: return palette.orange; case .limit: return palette.red }
    }

    private func color(for band: CockpitReadings.WindBand) -> Color {
        switch band { case .calm: return palette.green; case .breeze: return palette.yellow; case .gusty: return palette.orange; case .storm: return palette.red }
    }

    private func color(for band: CockpitReadings.PulseBand) -> Color {
        switch band { case .idle: return CockpitGlass.dim; case .ok: return palette.green; case .caution: return palette.orange; case .silent: return palette.red }
    }

    // MARK: Lamps

    private var lamps: some View {
        let l = readings.lamps
        let row1 = [CockpitLamp(text: "PAUSED", lit: l.paused, tint: palette.orange), CockpitLamp(text: "STEP FAILED", lit: l.stepFailed, tint: palette.red),
                    CockpitLamp(text: "LIMIT", lit: l.limitReached, tint: palette.red)]
        let row2 = [CockpitLamp(text: "SILENT", lit: l.silent, tint: palette.orange), CockpitLamp(text: "SUPERVISOR OFF", lit: l.supervisorOff, tint: palette.yellow)]
        // One row when the panel is wide enough, two rows or one column at a large text size or in a narrow window.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(row1.indices, id: \.self) { row1[$0] }; ForEach(row2.indices, id: \.self) { row2[$0] } }
            VStack(spacing: 8) {
                HStack(spacing: 8) { ForEach(row1.indices, id: \.self) { row1[$0] } }
                HStack(spacing: 8) { ForEach(row2.indices, id: \.self) { row2[$0] } }
            }
            VStack(spacing: 8) { ForEach(row1.indices, id: \.self) { row1[$0] }; ForEach(row2.indices, id: \.self) { row2[$0] } }
        }
        .frame(maxWidth: .infinity)
    }
}
