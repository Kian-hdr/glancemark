import Markdown
import SwiftUI

struct ReaderTable<Cell: View>: View {
    let table: Markdown.Table
    @ViewBuilder let cell: (any Markup) -> Cell

    var body: some View {
        let rows = [Array(table.head.children)] + table.body.children.map { Array($0.children) }
        let alignment = table.columnAlignments
        let border = Color.primary.opacity(0.16)
        let outline = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            let position = column < alignment.count ? alignment[column] : nil
                            let cellAlignment: Alignment = position == .right ? .trailing
                                : position == .center ? .center : .leading
                            cell(rows[row][column])
                                .fontWeight(row == 0 ? .semibold : .regular)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cellAlignment)
                                .overlay(alignment: .trailing) {
                                    if column < rows[row].count - 1 {
                                        Rectangle().fill(border).frame(width: 1)
                                    }
                                }
                        }
                    }
                    .background(row == 0 ? Color.primary.opacity(0.055) : Color.clear)
                    if row < rows.count - 1 {
                        Rectangle().fill(border).frame(height: 1)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(outline)
            .overlay { outline.strokeBorder(border, lineWidth: 1).allowsHitTesting(false) }
        }
    }
}
