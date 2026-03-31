import SwiftUI

struct TOCView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(spacing: 0) {
            VSDarkHeader(title: "Table of Contents")
            Divider().background(VSDark.border)

            if let idx = workspaceManager.activeTabIndex as Int?,
               idx >= 0, idx < workspaceManager.openTabs.count {
                let tab = workspaceManager.openTabs[idx]

                if tab.headings.isEmpty {
                    emptyState("No Headings")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tab.headings) { heading in
                                Button(action: {
                                    workspaceManager.updateActiveHeading(heading.id)
                                    NotificationCenter.default.post(name: NSNotification.Name("ScrollToHeading"), object: heading.id)
                                }) {
                                    HStack(spacing: 4) {
                                        if heading.level > 1 {
                                            Color.clear.frame(width: CGFloat(heading.level - 1) * 12)
                                        }
                                        Circle()
                                            .fill(heading.id == tab.activeHeadingId ? VSDark.blue : VSDark.textDim.opacity(0.4))
                                            .frame(width: 5, height: 5)
                                        Text(heading.text)
                                            .font(.system(size: 12))
                                            .foregroundColor(heading.id == tab.activeHeadingId ? VSDark.textBright : VSDark.text)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(heading.id == tab.activeHeadingId ? VSDark.selection.opacity(0.3) : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .background(VSDark.bgSidebar)
                }
            } else {
                emptyState("No File Open")
            }
        }
        .background(VSDark.bgSidebar)
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(VSDark.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSDark.bgSidebar)
    }
}

#Preview {
    TOCView().environmentObject(WorkspaceManager())
}
