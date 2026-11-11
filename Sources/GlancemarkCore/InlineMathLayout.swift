import SwiftUI

struct InlineMathLayout: Layout {
    var horizontalSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let item = result.items[index]
            subview.place(at: CGPoint(x: bounds.minX + item.minX, y: bounds.minY + item.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(item.size))
        }
    }

    private func positions(width: CGFloat, subviews: Subviews) -> (items: [CGRect], size: CGSize) {
        var items: [CGRect] = []
        var row: [(CGFloat, ViewDimensions)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var usedWidth: CGFloat = 0

        func flush() {
            guard !row.isEmpty else { return }
            let baseline = row.map { $0.1[.firstTextBaseline] }.max() ?? 0
            let descent = row.map { $0.1.height - $0.1[.firstTextBaseline] }.max() ?? 0
            items += row.map { position, dimensions in
                CGRect(x: position, y: y + baseline - dimensions[.firstTextBaseline],
                       width: dimensions.width, height: dimensions.height)
            }
            usedWidth = max(usedWidth, x)
            y += baseline + descent + 2
            x = 0
            row = []
        }

        for view in subviews {
            var dimensions = view.dimensions(in: .unspecified)
            if !row.isEmpty && x + horizontalSpacing + dimensions.width > width { flush() }
            if dimensions.width > width {
                dimensions = view.dimensions(in: ProposedViewSize(width: width, height: nil))
            }
            if !row.isEmpty { x += horizontalSpacing }
            row.append((x, dimensions))
            x += dimensions.width
        }
        flush()
        return (items, CGSize(width: usedWidth, height: max(0, y - 2)))
    }
}
