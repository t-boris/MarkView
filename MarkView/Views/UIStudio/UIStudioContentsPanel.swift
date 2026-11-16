import SwiftUI

/// The Contents panel beside a UI Studio tab: the session's facts.
struct UIStudioContentsPanel: View {
    @ObservedObject var session: StudioSession

    var body: some View {
        ScrollView {
            FactRows(rows: [("Tab", "UI Studio"), ("Application", session.target?.label ?? "—"), ("State", session.state.title),
                            ("Address", session.appURL?.absoluteString ?? "—"), ("Scenario", session.scenario.name),
                            ("Route", session.route), ("Changes", String(session.history.filter { $0.kind != .question }.count)),
                            ("Captures", String(session.captures.count))])
                .padding(10)
        }
    }
}
