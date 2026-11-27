import AppKit
import SwiftUI

extension CockpitRun.StepStatus {
    func tint(_ palette: AppPalette) -> Color {
        switch self {
        case .running: return palette.accent
        case .passed: return palette.green
        case .failed: return palette.red
        case .interrupted: return palette.orange
        case .skipped, .waiting: return palette.textDim
        }
    }

    var icon: String {
        switch self {
        case .running: return "play.circle.fill"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .interrupted: return "bolt.circle.fill"
        case .skipped: return "arrow.right.circle"
        case .waiting: return "circle"
        }
    }
}

/// Pure horizontal overflow and navigation math for `CockpitFlightPath`.
struct CockpitFlightPathLayout: Equatable {
    let stepCount: Int
    let cellWidth: CGFloat
    let containerWidth: CGFloat
    let viewportWidth: CGFloat
    let scrollOffset: CGFloat

    var contentWidth: CGFloat { CGFloat(stepCount) * cellWidth }
    /// Decided from the full container width so showing the scroll arrows never oscillates on resize.
    var overflows: Bool { containerWidth > 0 && contentWidth > containerWidth + 1 }
    private var activeViewport: CGFloat { viewportWidth > 0 ? viewportWidth : containerWidth }
    var maxScroll: CGFloat { max(0, contentWidth - activeViewport) }
    var clampedOffset: CGFloat { min(max(0, scrollOffset), maxScroll) }
    var canScrollLeading: Bool { overflows && clampedOffset > 6 }
    var canScrollTrailing: Bool { overflows && clampedOffset < maxScroll - 6 }

    /// Waypoints whose marker/title is clipped past the leading edge.
    var hiddenLeading: Int {
        guard overflows, cellWidth > 0 else { return 0 }
        return (0..<stepCount).filter { CGFloat($0) * cellWidth + 16 < clampedOffset }.count
    }

    /// Waypoints whose marker/title is clipped past the trailing edge.
    var hiddenTrailing: Int {
        guard overflows, cellWidth > 0 else { return 0 }
        let rightEdge = clampedOffset + activeViewport
        return (0..<stepCount).filter { CGFloat($0 + 1) * cellWidth - 16 > rightEdge }.count
    }

    /// Target waypoint index (anchored trailing) to reveal clipped trailing steps.
    func nextTrailingIndex() -> Int? {
        guard canScrollTrailing, stepCount > 0 else { return nil }
        let rightEdge = clampedOffset + activeViewport
        let firstClipped = (0..<stepCount).first { CGFloat($0 + 1) * cellWidth - 4 > rightEdge } ?? (stepCount - 1)
        let visibleCount = max(1, Int(floor(activeViewport / cellWidth)))
        let pageAdvance = max(0, visibleCount / 2 - 1)
        return min(stepCount - 1, firstClipped + pageAdvance)
    }

    /// Target waypoint index (anchored leading) to reveal clipped leading steps.
    func nextLeadingIndex() -> Int? {
        guard canScrollLeading, stepCount > 0 else { return nil }
        let lastClipped = (0..<stepCount).last { CGFloat($0) * cellWidth + 4 < clampedOffset } ?? 0
        let visibleCount = max(1, Int(floor(activeViewport / cellWidth)))
        let pageAdvance = max(0, visibleCount / 2 - 1)
        return max(0, lastClipped - pageAdvance)
    }
}

private struct FlightPathContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Observes the enclosing AppKit `NSScrollView`'s clip view so horizontal scroll position and viewport width stay accurate
/// across programmatic `ScrollViewReader.scrollTo`, trackpad/mouse scrolling, and window resizes.
private struct FlightPathScrollObserver: NSViewRepresentable {
    let onChange: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        let coordinator = context.coordinator
        view.onAttach = { [weak coordinator] scrollView in
            coordinator?.attach(to: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.attach(to: nsView.enclosingScrollView)
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ObserverView: NSView {
        var onAttach: ((NSScrollView?) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            onAttach?(enclosingScrollView)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onAttach?(enclosingScrollView)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onChange: (CGFloat, CGFloat) -> Void
        private weak var clipView: NSClipView?

        init(onChange: @escaping (CGFloat, CGFloat) -> Void) { self.onChange = onChange }

        func attach(to scrollView: NSScrollView?) {
            guard let next = scrollView?.contentView, clipView !== next else { return }
            detach()
            clipView = next
            next.postsBoundsChangedNotifications = true
            next.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(clipViewChanged(_:)), name: NSView.boundsDidChangeNotification, object: next)
            center.addObserver(self, selector: #selector(clipViewChanged(_:)), name: NSView.frameDidChangeNotification, object: next)
            Task { @MainActor [weak self] in self?.report() }
        }

        @objc private func clipViewChanged(_ note: Notification) {
            report()
        }

        func report() {
            guard let clipView else { return }
            onChange(max(0, clipView.bounds.origin.x), max(0, clipView.bounds.width))
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            clipView = nil
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// The plan as a route: a waypoint for every step, the leg behind a finished step drawn solid, and a plane above the step being flown.
/// Choosing a waypoint filters the timeline to that step, as the chips of the flow strip did.
/// When the route overflows the available width, explicit arrow controls, hidden-step counts, edge fades and the horizontal scroll bar
/// let the person see and reach every waypoint.
struct CockpitFlightPath: View {
    @Environment(\.palette) private var palette
    let run: CockpitRun
    /// The colour of the plane: the run's state.
    let tint: Color
    @Binding var selectedStepID: String?

    @State private var containerWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    static let cell: CGFloat = 116

    private var layout: CockpitFlightPathLayout {
        CockpitFlightPathLayout(stepCount: run.plan.steps.count, cellWidth: Self.cell,
                                containerWidth: containerWidth, viewportWidth: viewportWidth, scrollOffset: scrollOffset)
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .center, spacing: 6) {
                if layout.overflows {
                    scrollButton(leading: true, count: layout.hiddenLeading, enabled: layout.canScrollLeading) {
                        if let target = layout.nextLeadingIndex() {
                            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .leading) }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(run.plan.steps.enumerated()), id: \.element.id) { index, plan in
                            waypoint(index, plan).id(index)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(FlightPathScrollObserver { offset, viewport in
                        if abs(scrollOffset - offset) > 1 { scrollOffset = offset }
                        if abs(viewportWidth - viewport) > 1 { viewportWidth = viewport }
                    })
                }
                .overlay(alignment: .leading) {
                    if layout.canScrollLeading { edgeFade(leading: true) }
                }
                .overlay(alignment: .trailing) {
                    if layout.canScrollTrailing { edgeFade(leading: false) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Route of the plan")
                if layout.overflows {
                    scrollButton(leading: false, count: layout.hiddenTrailing, enabled: layout.canScrollTrailing) {
                        if let target = layout.nextTrailingIndex() {
                            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .trailing) }
                        }
                    }
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: FlightPathContainerWidthKey.self, value: geo.size.width)
            })
            .onPreferenceChange(FlightPathContainerWidthKey.self) { width in
                if abs(containerWidth - width) > 1 { containerWidth = width }
            }
            .onChange(of: run.currentIndex) { current in
                guard let current, layout.overflows, run.plan.steps.indices.contains(current) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    private func scrollButton(leading: Bool, count: Int, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if leading { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                if count > 0 {
                    Text(leading ? "\(count)" : "+\(count)")
                        .uiFont(size: 10, weight: .semibold, design: .monospaced)
                }
                if !leading { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundColor(enabled ? palette.text : palette.textDim.opacity(0.4))
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgSidebar))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(enabled ? palette.accent.opacity(0.55) : palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(leading ? "Show earlier steps" : "Show more steps")
        .accessibilityLabel(leading ? "Scroll route left" : "Scroll route right")
        .accessibilityValue(count > 0 ? "\(count) \(leading ? "earlier" : "more") step\(count == 1 ? "" : "s") hidden"
                                      : (leading ? "At start of route" : "At end of route"))
    }

    private func edgeFade(leading: Bool) -> some View {
        LinearGradient(colors: [palette.bg.opacity(0.92), palette.bg.opacity(0)],
                       startPoint: leading ? .leading : .trailing, endPoint: leading ? .trailing : .leading)
            .frame(width: 24)
            .allowsHitTesting(false)
    }

    private func flown(_ index: Int) -> Bool {
        guard run.steps.indices.contains(index) else { return false }
        return run.steps[index].status == .passed || run.steps[index].status == .skipped
    }

    private func waypoint(_ index: Int, _ plan: CockpitStep) -> some View {
        let status = run.steps.indices.contains(index) ? run.steps[index].status : .waiting
        // Every member of a running group is flown at once (REQ-004).
        let current = run.currentMembers.contains(index)
        let selected = selectedStepID == plan.id.uuidString
        let color = status.tint(palette)
        let last = index == run.plan.steps.count - 1
        return VStack(spacing: 4) {
            Image(systemName: "airplane").font(.system(size: 15, weight: .semibold)).foregroundColor(tint).opacity(current ? 1 : 0)
                .accessibilityHidden(true)
            ZStack {
                HStack(spacing: 0) {
                    leg(visible: index > 0, flown: flown(index - 1))
                    leg(visible: !last, flown: flown(index))
                }
                Button { selectedStepID = selected ? nil : plan.id.uuidString } label: {
                    ZStack {
                        Circle().fill(status == .passed ? color : palette.bgInput)
                        Circle().stroke(selected ? palette.accent : color, lineWidth: current || selected ? 2.5 : 1.5)
                        if status == .passed {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Color.black.opacity(0.8))
                        } else if status == .failed || status == .interrupted {
                            Image(systemName: status == .failed ? "xmark" : "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundColor(color)
                        } else {
                            Text("\(index + 1)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(current ? palette.accent : palette.textDim)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(plan.assignment)
                .accessibilityLabel("Step \(index + 1): \(plan.title)")
                .accessibilityValue(status.rawValue)
            }
            .frame(height: 26)
            Text(plan.title).uiFont(size: 10, weight: current ? .semibold : .regular).foregroundColor(current ? palette.text : palette.textDim)
                .multilineTextAlignment(.center).lineLimit(2).frame(width: 100, height: 28, alignment: .top)
        }
        .frame(width: Self.cell)
    }

    /// Half of the line between two waypoints: solid once the step behind it is done.
    private func leg(visible: Bool, flown: Bool) -> some View {
        Rectangle()
            .fill(visible ? (flown ? palette.green : palette.border) : Color.clear)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .opacity(visible && !flown ? 0.8 : 1)
    }
}

/// Who is flying the current step, or each member of the current group: its agent and model, how long it has worked and when the run
/// last showed it was alive.
struct CockpitFlightStrip: View {
    @Environment(\.palette) private var palette
    let run: CockpitRun
    let now: Date
    /// The latest sign of life of a run that is going; for a saved run, the one the record kept.
    let lastSignal: Date?
    let activeNow: Bool
    let showTerminal: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "cpu").foregroundColor(palette.accent)
            let members = run.currentMembers.filter { run.plan.steps.indices.contains($0) && run.steps.indices.contains($0) }
            if !members.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if members.count > 1 {
                        Text("\(members.count) steps run at the same time").uiFont(size: 11).foregroundColor(palette.textDim)
                    }
                    ForEach(members, id: \.self) { index in member(index) }
                    if let signal = lastSignal {
                        Text("Last sign of life \(CockpitFormat.duration(now.timeIntervalSince(signal))) ago").uiFont(size: 11).foregroundColor(palette.textDim)
                    }
                }
                Spacer(minLength: 8)
                if activeNow && members.contains(where: { run.steps[$0].status == .running }) {
                    Button("Show agent terminal", action: showTerminal).buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Text(run.status == .finished ? "No step is running; the run finished." : "No step is running.").uiFont(size: 12).foregroundColor(palette.textDim)
                Spacer(minLength: 0)
            }
        }
        .cockpitCard(padding: 10)
    }

    private func member(_ index: Int) -> some View {
        let plan = run.plan.steps[index], record = run.steps[index]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Step \(index + 1) of \(run.steps.count) · \(plan.title)").uiFont(size: 12, weight: .semibold).lineLimit(1)
                CockpitChip(text: "\(plan.agent) · \(plan.chosenModel ?? "default model")", icon: "cpu")
            }
            if record.status == .running, let started = record.startedAt {
                Text("Working for \(CockpitFormat.duration(now.timeIntervalSince(started)))").uiFont(size: 11)
            } else if run.isAtGroup, record.status == .passed || record.status == .failed {
                Text(record.status == .passed ? "Ended: passed; waiting for the rest of the group" : "Ended: failed; waiting for the rest of the group")
                    .uiFont(size: 11).foregroundColor(record.status == .passed ? palette.green : palette.red)
            }
        }
    }
}
