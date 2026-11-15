import SwiftUI

/// The items of the Layout menu, in the View menu and in the toolbar: one button per preset of the catalog, then the layout files that
/// could not be used, with the reason, and a button that reads the folders again (`AR-33`). The caller applies the choice to its window.
struct LayoutMenuItems: View {
    let library: LayoutLibrary
    /// The window has a folder, so there is something to arrange.
    let enabled: Bool
    let apply: (LayoutPreset) -> Void
    let reload: () -> Void

    /// How many unusable files the menu names; the rest are counted.
    private static let ignoredShown = 5

    var body: some View {
        ForEach(library.presets) { preset in
            Button { apply(preset) } label: { Label(preset.name, systemImage: preset.symbol) }
                .help(preset.summary)
                .disabled(!enabled)
        }
        Divider()
        Button("Reload Layouts", action: reload)
        if !library.ignored.isEmpty {
            Divider()
            Text("Not loaded:")
            ForEach(library.ignored.prefix(Self.ignoredShown)) { problem in
                Text("\(problem.file): \(problem.reason)")
            }
            if library.ignored.count > Self.ignoredShown {
                Text("and \(library.ignored.count - Self.ignoredShown) more (see the log)")
            }
        }
    }
}
