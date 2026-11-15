struct EditableReadingLayout {
    enum Side: Hashable { case before, after }

    enum Item: Equatable, Identifiable {
        case block(Int)
        case fragment(Int, Side, Range<Int>)
        case footnotes
        case editor

        enum ID: Hashable {
            case block(Int)
            case fragment(Int, Side)
            case footnotes
            case editor
        }

        var id: ID {
            switch self {
            case let .block(index): return .block(index)
            case let .fragment(index, side, _): return .fragment(index, side)
            case .footnotes: return .footnotes
            case .editor: return .editor
            }
        }
    }

    let items: [Item]
    let showsTail: Bool

    init(ranges: [Range<Int>?], active: Range<Int>?, byteCount: Int) {
        guard let active, active.lowerBound >= 0, active.upperBound <= byteCount else {
            items = ranges.indices.map(Item.block) + [.footnotes]
            showsTail = true
            return
        }

        var result: [Item] = []
        var inserted = false
        for (index, range) in ranges.enumerated() {
            guard let range, range.upperBound > active.lowerBound else {
                result.append(.block(index))
                continue
            }

            if range.lowerBound >= active.upperBound {
                if !inserted {
                    result.append(.editor)
                    inserted = true
                }
                result.append(.block(index))
                continue
            }

            if range.lowerBound < active.lowerBound {
                result.append(.fragment(index, .before, range.lowerBound..<active.lowerBound))
            }
            if !inserted {
                result.append(.editor)
                inserted = true
            }
            if range.upperBound > active.upperBound {
                result.append(.fragment(index, .after, active.upperBound..<range.upperBound))
            }
        }
        result.append(.footnotes)
        if !inserted { result.append(.editor) }
        items = result
        showsTail = inserted
    }
}
