import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(workspaceManager.openTabs.enumerated()), id: \.element.id) { index, tab in
                    tabItem(tab: tab, index: index)
                }
            }
        }
        .frame(height: 30)
        .background(VSDark.bg)
        .overlay(Rectangle().frame(height: 1).foregroundColor(VSDark.border), alignment: .bottom)
    }

    private func tabItem(tab: OpenTab, index: Int) -> some View {
        let isActive = index == workspaceManager.activeTabIndex

        return HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(isActive ? VSDark.blue : VSDark.textDim)

            if tab.isModified {
                Circle()
                    .fill(VSDark.orange)
                    .frame(width: 6, height: 6)
            }

            Text(tab.displayName)
                .font(.system(size: 12))
                .foregroundColor(isActive ? VSDark.textBright : VSDark.textDim)
                .lineLimit(1)

            Button(action: { workspaceManager.closeTab(at: index) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundColor(VSDark.textDim)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isActive ? VSDark.bgSidebar : VSDark.bg)
        .overlay(
            Rectangle().frame(height: 2)
                .foregroundColor(isActive ? VSDark.blue : Color.clear),
            alignment: .top
        )
        .overlay(Rectangle().frame(width: 1).foregroundColor(VSDark.border), alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { workspaceManager.activeTabIndex = index }
        .help(relativePath(for: tab))
        .contextMenu {
            Button("Reveal in File Tree") {
                workspaceManager.revealInFileTree(url: tab.url)
            }
            Divider()
            Button("Close") {
                workspaceManager.closeTab(at: index)
            }
            Button("Close Others") {
                workspaceManager.closeOtherTabs(except: index)
            }
            Button("Close Tabs to the Right") {
                workspaceManager.closeTabsToRight(of: index)
            }
            Button("Close All") {
                workspaceManager.closeAllTabs()
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url.path, forType: .string)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(tab.url.path, inFileViewerRootedAtPath: "")
            }
        }
    }

    private func relativePath(for tab: OpenTab) -> String {
        guard let root = workspaceManager.rootNode?.url else { return tab.url.path }
        let rootPath = root.path
        let filePath = tab.url.path
        if filePath.hasPrefix(rootPath) {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
    }
}
