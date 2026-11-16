import SwiftUI

/// A label and a value, in the style of the file facts.
struct FactRows: View {
    @Environment(\.palette) private var palette
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0).uiFont(size: 10).foregroundColor(palette.textDim).frame(width: 70, alignment: .leading)
                    Text(row.1).uiFont(size: 10).foregroundColor(palette.text).textSelection(.enabled)
                        .lineLimit(4).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
