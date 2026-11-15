import SwiftUI

/// The row of Files under the search field: which view, which filters, which sort (AC-1, AC-3, AC-4).
/// Every choice is visible on the controls themselves: the selected segment, a filled filter icon with
/// the number of active settings, and the sort field and direction.
struct FileBrowserControls: View {
    @Environment(\.palette) private var palette
    @Binding var preferences: FileBrowserPreferences
    @Binding var sort: FileTreeSortOrder
    /// The project is in a Git repository, so "Hide Git-ignored" means something.
    let canHideIgnored: Bool

    var body: some View {
        // One row when the sidebar is wide enough, otherwise the view picker above the filter and sort menus, so
        // nothing is clipped in the narrowest sidebar.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                viewPicker
                Spacer(minLength: 0)
                filterMenu
                sortMenu
            }
            VStack(alignment: .leading, spacing: 4) {
                viewPicker
                HStack(spacing: 8) {
                    filterMenu
                    Spacer(minLength: 0)
                    sortMenu
                }
            }
        }
    }

    private var viewPicker: some View {
        Picker("Files view", selection: $preferences.mode) {
            ForEach(FileBrowserViewMode.allCases) { mode in
                Image(systemName: mode.symbol)
                    .accessibilityLabel(mode.title)
                    .help(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("View: Icons, List or Tree")
        .accessibilityLabel("Files view")
        .accessibilityValue(preferences.mode.title)
    }

    /// Number of filter settings that differ from the defaults and apply to this project.
    private var activeCount: Int {
        (preferences.showHidden ? 1 : 0) + (canHideIgnored && preferences.hideIgnored ? 1 : 0) + (preferences.category == .all ? 0 : 1)
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Show hidden files and folders", isOn: $preferences.showHidden)
            if canHideIgnored {
                Toggle("Hide files ignored by Git", isOn: $preferences.hideIgnored)
            }
            Divider()
            Picker("Show", selection: $preferences.category) {
                ForEach(FileBrowserCategory.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Reset Filters") {
                preferences.showHidden = false
                preferences.hideIgnored = false
                preferences.category = .all
            }
            .disabled(activeCount == 0)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: activeCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                Text(activeCount == 0 ? "Filter" : "Filter · \(activeCount)")
            }
            .uiFont(size: 10, weight: .medium)
            .foregroundColor(activeCount == 0 ? palette.textDim : palette.blue)
            .fixedSize()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(filterSummary)
        .accessibilityLabel("Filters")
        .accessibilityValue(filterSummary)
    }

    private var filterSummary: String {
        var parts: [String] = []
        parts.append(preferences.showHidden ? "hidden items shown" : "hidden items excluded")
        if canHideIgnored { parts.append(preferences.hideIgnored ? "Git-ignored items hidden" : "Git-ignored items shown") }
        parts.append("showing \(preferences.category.title.lowercased())")
        return "Filters: " + parts.joined(separator: ", ")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort.field) {
                ForEach(FileTreeSortField.allCases, id: \.self) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $sort.ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down").uiFont(size: 8, weight: .bold)
                Text(sort.field == .name ? "Name" : "Date")
            }
            .uiFont(size: 10, weight: .medium)
            .foregroundColor(palette.text)
            .fixedSize()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(sortSummary)
        .accessibilityLabel("Sort")
        .accessibilityValue(sortSummary)
    }

    private var sortSummary: String {
        "Sorted by \(sort.field.rawValue), \(sort.ascending ? "ascending" : "descending"); folders first"
    }
}
