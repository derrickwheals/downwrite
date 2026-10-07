import SwiftUI
import DownwriteCore

/// What the table-of-contents sidebar shows. The editor coordinator keeps it in step with the document and the caret;
/// the sidebar only reads it and reports clicks back through `select`.
@MainActor
final class TOCModel: ObservableObject {
    @Published private(set) var rows: [TOCRow] = []
    /// Row of the heading whose section holds the caret.
    @Published private(set) var activeID: Int?
    /// Set by the editor: moves the caret to heading `id` and scrolls it into view.
    var onSelect: ((Int) -> Void)?

    func update(rows newRows: [TOCRow], activeID newActive: Int?) {
        if rows != newRows { rows = newRows }
        if activeID != newActive { activeID = newActive }
    }

    func select(_ id: Int) { onSelect?(id) }
}

/// The right-hand sidebar: the document's headings, nested by level. Click one to jump there.
struct TOCSidebar: View {
    @ObservedObject var model: TOCModel

    var body: some View {
        Group {
            if model.rows.isEmpty {
                TOCEmptyState()
            } else {
                TOCList(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table of Contents")
        .accessibilityIdentifier("toc-sidebar")
    }
}

private struct TOCList: View {
    @ObservedObject var model: TOCModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    Text("Contents")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(model.rows) { row in
                        TOCRowView(row: row, isActive: row.id == model.activeID) { model.select(row.id) }
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .onAppear {
                if let id = model.activeID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }
}

private struct TOCRowView: View {
    let row: TOCRow
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let indent: CGFloat = 14

    private var title: String { row.title.isEmpty ? "Untitled" : row.title }

    /// Top-level entries stand out; each step of nesting gets quieter.
    private var font: Font {
        switch row.depth {
        case 0: return .system(size: 13, weight: .semibold)
        case 1: return .system(size: 13)
        default: return .system(size: 12)
        }
    }

    private var foreground: Color {
        if isActive || row.depth == 0 { return .primary }
        return row.depth == 1 ? Color.primary.opacity(0.78) : .secondary
    }

    private var fill: Color {
        if isActive { return Color.accentColor.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .italic(row.title.isEmpty)
                .foregroundStyle(row.title.isEmpty ? Color.secondary : foreground)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8 + CGFloat(row.depth) * Self.indent)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue("Heading level \(row.level)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("toc-row-\(row.id)")
    }
}

private struct TOCEmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No headings yet")
                .font(.system(size: 13, weight: .medium))
            Text("Start a line with # to add one.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toc-empty")
    }
}
