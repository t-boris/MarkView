import SwiftUI

/// The Cockpit tab: the runs of this project on the left, and on the right either the plan being written or one run being watched.
struct CockpitView: View {
    @ObservedObject var session: CockpitSession

    var body: some View {
        HStack(spacing: 0) {
            CockpitRunList(session: session).frame(width: 220)
            Divider()
            switch session.screen {
            case .plan: CockpitPlanScreen(session: session)
            case .live: CockpitRunScreen(session: session, runID: nil)
            case .saved(let id): CockpitRunScreen(session: session, runID: id).id(id)
            }
        }
        .onAppear { session.loadRuns(); session.refreshAgents() }
    }
}
