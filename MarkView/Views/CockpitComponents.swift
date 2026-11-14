import SwiftUI

/// A small rounded label: a state, a badge, an agent and its model.
struct CockpitChip: View {
    @Environment(\.palette) private var palette
    let text: String
    var icon: String?
    var tint: Color?

    var body: some View {
        let color = tint ?? palette.textDim
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text).uiFont(size: 11, weight: .medium).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundColor(color)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.15)))
    }
}

/// A panel: the grouping used on both Cockpit screens.
private struct CockpitCardStyle: ViewModifier {
    @Environment(\.palette) private var palette
    var padding: CGFloat
    var outline: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.bgSidebar))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(outline ?? palette.border, lineWidth: outline == nil ? 1 : 1.5))
    }
}

extension View {
    func cockpitCard(padding: CGFloat = 12, outline: Color? = nil) -> some View { modifier(CockpitCardStyle(padding: padding, outline: outline)) }
}

/// A section title with its helper line.
struct CockpitSectionTitle: View {
    @Environment(\.palette) private var palette
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).uiFont(size: 13, weight: .semibold)
            if let detail { Text(detail).uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

enum CockpitFormat {
    /// "40 s", "12 min", "3 h 5 min", "2 d 4 h": how long something has gone on, for a run that may last days.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) d \(hours % 24) h"
    }

    /// The time of day for today's events, the date and the time for older ones.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}

/// An editable list of short texts: success criteria, unavailable outcomes, alternatives.
struct CockpitTextList: View {
    @Environment(\.palette) private var palette
    let title: String
    let detail: String?
    let items: [String]
    let addTitle: String
    let onChange: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CockpitSectionTitle(title: title, detail: detail)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Text("•").foregroundColor(palette.textDim)
                    TextField("", text: Binding(get: { item }, set: { value in var next = items; next[index] = value; onChange(next) }), axis: .vertical)
                        .textFieldStyle(.plain).uiFont(size: 12)
                    Button { var next = items; next.remove(at: index); onChange(next) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundColor(palette.textDim).help("Remove")
                }
            }
            Button { onChange(items + [""]) } label: { Label(addTitle, systemImage: "plus.circle") }
                .buttonStyle(.plain).uiFont(size: 12).foregroundColor(palette.accent)
        }
    }
}

/// A chip that opens a menu of the available agents and, for each, its models. `agent` nil means the project's own assistant
/// (offered only when `inheritLabel` is given).
struct CockpitAgentMenu: View {
    @Environment(\.palette) private var palette
    let agents: [CockpitAgentChoice]
    let agent: String?
    let model: String?
    var inheritLabel: String?
    let onSelect: (String?, String?) -> Void

    private var choice: CockpitAgentChoice? { agents.first { $0.name == agent } }

    private var label: String {
        guard let agent else { return inheritLabel ?? "Choose an agent" }
        guard let choice else { return "\(agent) · unavailable" }
        return "\(choice.name) · \(choice.label(forModel: model))"
    }

    var body: some View {
        Menu {
            if let inheritLabel {
                Button { onSelect(nil, nil) } label: { if agent == nil { Label(inheritLabel, systemImage: "checkmark") } else { Text(inheritLabel) } }
            }
            ForEach(agents) { entry in
                Menu(entry.name) {
                    item(entry, model: nil, name: entry.label(forModel: nil))
                    ForEach(entry.models.filter { !$0.id.isEmpty }) { item(entry, model: $0.id, name: $0.name) }
                }
            }
            if agents.isEmpty { Text("No agent is available") }
        } label: {
            CockpitChip(text: label, icon: agent != nil && choice == nil ? "exclamationmark.triangle.fill" : "cpu",
                        tint: agent != nil && choice == nil ? palette.red : palette.accent)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func item(_ entry: CockpitAgentChoice, model value: String?, name: String) -> some View {
        Button { onSelect(entry.name, value) } label: {
            if agent == entry.name && model == value { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }
}
