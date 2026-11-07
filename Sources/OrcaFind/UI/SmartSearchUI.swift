import SwiftUI

// MARK: - S10 · Editing a "Looks like" chip

/// Popover opened by clicking a "Looks like" chip: correct the guess, pick a similar thing Orca
/// has actually seen in this Mac's photos, search the word as text instead, or drop it.
struct LookEditor: View {
    @Environment(AppState.self) private var state
    let chip: QueryChip
    var dismiss: () -> Void

    @State private var text = ""
    @State private var related: [String] = []
    @State private var seen = 0
    @FocusState private var focused: Bool

    private var look: LookTerm? { state.parsed.looks.first { "Looks like: " + $0.word == chip.label } }

    var body: some View {
        let word = look?.word ?? ""
        VStack(alignment: .leading, spacing: 12) {
            PixelLabel("Looks like")
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(DS.text2)
                TextField("", text: $text).textFieldStyle(.plain).font(DS.body).focused($focused)
                    .onSubmit { apply(text) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.focus, lineWidth: 1.5))

            if !related.isEmpty {
                PixelLabel("Similar things Orca can spot")
                FlowLayout(spacing: 6) {
                    ForEach(related, id: \.self) { r in
                        Button { apply(VisualAnalyzer.display(r)) } label: { Badge(VisualAnalyzer.display(r)) }
                            .buttonStyle(.plain).handCursor()
                    }
                }
            }
            Rectangle().fill(DS.border).frame(height: 1)
            action("text.viewfinder", "Search for the word “\(word)” in text instead") { state.lookAsText(chip) }
            if !related.isEmpty {
                action("eye", "Also show similar things (\(related.prefix(2).map(VisualAnalyzer.display).joined(separator: ", ")))") {
                    state.widenLook(chip, with: related)
                }
            }
            action("xmark", chip.isGuess ? "Remove this guess" : "Remove", tint: DS.critical) { state.removeChip(chip) }
            Text(seen > 0
                 ? "Seen in \(Fmt.plural(seen, "picture")) on this Mac with 90%+ confidence."
                 : "Not seen clearly in any picture yet — matching by name and text too.")
                .font(DS.caption).foregroundStyle(DS.text2)
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            text = word
            let labels = look?.labels ?? []
            related = VisualStore.shared.related(to: labels, limit: 4)
            seen = VisualStore.shared.count(labels: labels, min: 0.9)
            focused = true
        }
    }

    private func apply(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty && v.lowercased() != look?.word { state.replaceLook(chip, with: v) }
        dismiss()
    }

    private func action(_ icon: String, _ label: String, tint: Color = DS.text, _ run: @escaping () -> Void) -> some View {
        Button { run(); dismiss() } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                Text(label).font(DS.bodySM).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }
}

// MARK: - S11 · Nothing matches

/// Shown instead of a dead end when a picture search finds nothing: says what was checked and
/// loosens one thing at a time (date first, then the guess), with close matches labelled as such.
struct WaysOutView: View {
    @Environment(AppState.self) private var state
    let width: CGFloat
    @State private var ways: SearchEngine.WaysOut?

    var body: some View {
        let q = state.parsed
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Try one of these").font(DS.headingSM).foregroundStyle(DS.text)
                FlowLayout(spacing: 8) {
                    if let w = ways, w.anyDate > 0, let dateChip = q.chips.first(where: { $0.kind == .date }) {
                        Button("Any date — \(Fmt.plural(w.anyDate, "match", "matches"))") { state.removeChip(dateChip) }.buttonStyle(.primary)
                    }
                    if let t = ways?.asText, t.count > 0, let chip = q.chips.first(where: { $0.label == "Looks like: " + t.word }) {
                        Button("Search “\(t.word)” in text — \(Fmt.count(t.count))") { state.lookAsText(chip) }.buttonStyle(.secondary)
                    }
                    ForEach(q.chips.filter { $0.kind != .type && $0.kind != .looks }.suffix(2)) { c in
                        Button("Remove “\(c.label)”") { state.removeChip(c) }.buttonStyle(.secondary)
                    }
                }
                if ways == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking what would help…").font(DS.caption).foregroundStyle(DS.text2) }
                } else if ways?.anyDate == 0 && (ways?.asText?.count ?? 0) == 0 && (ways?.close.isEmpty ?? true) {
                    Text("Nothing close either. Try describing it differently, or remove a chip.").font(DS.bodySM).foregroundStyle(DS.text2)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(14)

            if let w = ways, !w.close.isEmpty {
                PixelLabel("Close matches · look partly like what you described")
                CardGrid(items: w.close, width: width, target: CGFloat(state.prefs.cardSize) + 30, snippets: w.closeReasons)
            }
        }
        .task(id: q) {
            ways = nil
            let items = state.index.items
            ways = await Task.detached(priority: .userInitiated) { SearchEngine.waysOut(q, in: items) }.value
        }
    }

    /// "Nothing that looks like a zebra · yesterday"
    static func title(_ q: ParsedQuery) -> String {
        let what = q.looks.first.map { "Nothing that looks like " + VisualAnalyzer.phrase($0.word.replacingOccurrences(of: " ", with: "_")) }
            ?? (q.coverColours.isEmpty ? "No matches" : "No \(QueryParser.colourLabel(q).lowercased()) covers")
        let date = q.chips.first { $0.kind == .date }?.label.lowercased()
        return date.map { what + " · " + $0 } ?? what
    }
}
