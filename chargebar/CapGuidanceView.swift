import AppKit

/// Cap-vs-cycle-life reference table shown inside the "Charge limit" submenu,
/// so the tradeoff is visible at the point of decision (README: In-app guidance).
@MainActor
final class CapGuidanceView: NSView {
    struct Row {
        let cap: Int
        let label: String
        let cycles: String
        let multiplier: String
    }

    static let rows: [Row] = [
        Row(cap: 100, label: "100%", cycles: "~500", multiplier: "1x (baseline)"),
        Row(cap: 85, label: "85%", cycles: "~800", multiplier: "1.6x"),
        Row(cap: 80, label: "80%", cycles: "~1200", multiplier: "2.4x"),
        Row(cap: 75, label: "75%", cycles: "~1800", multiplier: "3.6x"),
        Row(cap: 70, label: "70%", cycles: "~2500", multiplier: "5x"),
        Row(cap: 60, label: "60%", cycles: "~4000+", multiplier: "8x"),
        Row(cap: 50, label: "50% (storage)", cycles: "~6000+", multiplier: "12x"),
    ]

    static let copy = "Cycles are cumulative \u{2014} 10 partial charges of 10% = 1 cycle. "
        + "Sitting at the cap also ages the battery, but far less than sitting at 100%. "
        + "Lower cap = longer life, less runtime. 75% is the sweet spot for most mixed use."

    private static let width: CGFloat = 340
    private static let inset: CGFloat = 14

    /// The table row closest to `cap`; custom values highlight their nearest reference row.
    static func highlightedRow(for cap: Int) -> Int {
        rows.indices.min { abs(rows[$0].cap - cap) < abs(rows[$1].cap - cap) } ?? 0
    }

    init(selectedCap: Int) {
        super.init(frame: .zero)
        build(selectedCap: selectedCap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build(selectedCap: Int) {
        let highlighted = Self.highlightedRow(for: selectedCap)
        let contentWidth = Self.width - Self.inset * 2

        let grid = NSGridView(views: [header("Cap"), header("Cycles to 80% health"), header("vs 100%")].asRow)
        for (i, row) in Self.rows.enumerated() {
            let selected = i == highlighted
            grid.addRow(with: [cell(row.label, selected), cell(row.cycles, selected), cell(row.multiplier, selected)])
        }
        grid.rowSpacing = 0
        grid.columnSpacing = 10
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        for r in 0..<grid.numberOfRows {
            grid.row(at: r).topPadding = 2
            grid.row(at: r).bottomPadding = 2
        }

        let highlight = NSView()
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        highlight.layer?.cornerRadius = 4

        let note = NSTextField(wrappingLabelWithString: Self.copy)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = contentWidth

        let source = NSTextField(labelWithString: "Source: RESEARCH.md (Battery University, Argonne)")
        source.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        source.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [grid, note, source])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: Self.inset, bottom: 8, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlight)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.widthAnchor.constraint(equalToConstant: contentWidth),
            note.widthAnchor.constraint(equalToConstant: contentWidth),
        ])

        frame = NSRect(origin: .zero, size: NSSize(width: Self.width, height: stack.fittingSize.height))
        layoutSubtreeIfNeeded()

        // Header is grid row 0, so table row i is grid row i + 1.
        let cellFrame = grid.cell(atColumnIndex: 0, rowIndex: highlighted + 1).contentView?.frame ?? .zero
        let rowInStack = grid.convert(NSRect(x: 0, y: cellFrame.minY - 2, width: grid.bounds.width, height: cellFrame.height + 4), to: self)
        highlight.frame = rowInStack.insetBy(dx: -6, dy: 0)
    }

    private func header(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func cell(_ text: String, _ selected: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: selected ? .semibold : .regular)
        field.textColor = .labelColor
        return field
    }
}

private extension Array where Element == NSTextField {
    var asRow: [[NSView]] { [self] }
}
