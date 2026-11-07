import SwiftUI
import AppKit

// MARK: - F1 · Library tile

struct SmartFolderTile: View {
    @Environment(AppState.self) private var state
    let folder: SmartFolder
    var width: CGFloat

    var body: some View {
        let st = state.folderStats[folder.id]
        let kind = st?.kind ?? .documents
        let s = width / 200
        GlassFolder(title: folder.name, meta: st.map { "\(Fmt.plural($0.count, "file")) · \(Fmt.size($0.size))" } ?? "Counting…",
                    palette: .of(kind), style: .of(kind), items: st?.preview ?? [], width: width) {
            state.navigate(.smartFolder(folder.id))
        }
        .overlay(alignment: .topTrailing) {
            if let n = st?.newCount, n > 0 {
                Badge("\(n) new", tone: .info).padding(.top, 10 * s).padding(.trailing, 14 * s).allowsHitTesting(false)
            }
        }
        .contextMenu { SmartFolderMenu(folder: folder) }
        .help(folder.rules.map { $0.summary(sources: state.homeStats.sources) }.joined(separator: folder.matchAll ? " · " : " or "))
    }
}

/// Right-click menu for a smart folder (F6), also behind the ··· button inside one.
struct SmartFolderMenu: View {
    @Environment(AppState.self) private var state
    let folder: SmartFolder
    var includeOpen = true

    var body: some View {
        if includeOpen { Button("Open") { state.navigate(.smartFolder(folder.id)) } }
        Button("Rename…") { state.renamingFolder = folder }
        Button("Edit Rules…") { state.editRules(folder.id) }
        Button("Duplicate") { state.duplicateFolder(folder.id) }
        Toggle("Show on Home", isOn: Binding(get: { state.folder(folder.id)?.showOnHome ?? false }, set: { _ in state.toggleOnHome(folder.id) }))
        Divider()
        Button("Delete Smart Folder…", role: .destructive) { state.deletingFolder = folder }
    }
}

/// Dashed "+" tile at the end of a folder row.
struct AddTile: View {
    let title: String
    let width: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                Text(title).font(DS.bodySM)
            }
            .foregroundStyle(DS.text2)
            .frame(width: width - 8, height: width * 0.84 - 8)
            .background(RoundedRectangle(cornerRadius: 18).fill(DS.surface.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(DS.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

// MARK: - F2 · Save a search as a smart folder

struct SaveFolderPopover: View {
    @Environment(AppState.self) private var state
    var dismiss: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let rules = state.currentSearchRules
        let count = state.visibleItems.count
        VStack(alignment: .leading, spacing: 12) {
            PixelLabel("Save as smart folder")
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(DS.text2)
                TextField("", text: $name, prompt: Text("Name").foregroundStyle(DS.text3))
                    .textFieldStyle(.plain).font(DS.body).focused($focused)
                    .onSubmit(create)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.focus, lineWidth: 1.5))

            PixelLabel("Keeps itself filled with")
            if rules.isEmpty {
                Text("Nothing to keep yet — type a search first.").font(DS.bodySM).foregroundStyle(DS.text2)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(rules) { r in Chip(label: r.summary(sources: state.homeStats.sources), symbol: r.field.symbol, style: .understood) }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 11)).padding(.top, 2)
                Text("\(Fmt.plural(count, "file")) now. New files that match will show up here on their own.")
                    .font(DS.bodySM).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(DS.Tone.info.fg)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Tone.info.bg))
            Rectangle().fill(DS.border).frame(height: 1)
            HStack(spacing: 8) {
                Button("Edit as rules…") {
                    let n = name
                    dismiss()
                    state.newFolderSheet(rules: rules, name: n)
                }
                .buttonStyle(.plainP).disabled(rules.isEmpty)
                Spacer()
                Button("Cancel", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button("Create folder", action: create).buttonStyle(.primary).disabled(rules.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            name = SmartFolder.suggestedName(for: state.searchText)
            focused = true
        }
    }

    private func create() {
        guard !state.currentSearchRules.isEmpty else { return }
        let n = name
        dismiss()
        state.saveCurrentSearchAsFolder(name: n)
    }
}

// MARK: - F3 · New smart folder / Edit rules

struct SmartFolderSheet: View {
    @Environment(AppState.self) private var state
    @State private var draft: FolderDraft
    @State private var reading = false
    @State private var note: String?
    @State private var matches: [FileItem] = []
    @State private var matchCount = 0
    @State private var counting = true
    @FocusState private var focus: Focus?
    private enum Focus { case name, describe }

    init(draft: FolderDraft) { _draft = State(initialValue: draft) }

    private var validRules: Bool { draft.folder.rules.contains { $0.query() != nil } }
    private var canSave: Bool { validRules && !draft.folder.name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var previewKey: String {
        draft.folder.rules.map { "\($0.field.rawValue)=\($0.value)" }.joined(separator: "|") + "\(draft.folder.matchAll)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.isNew ? "New smart folder" : "Edit “\(draft.folder.name)”").font(DS.headingMD).foregroundStyle(DS.text).lineLimit(1)
                Spacer()
                IconBtn(symbol: "xmark", help: "Close (esc)") { close() }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Rectangle().fill(DS.border).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                ScrollView { rulesColumn.padding(20) }
                    .frame(maxWidth: .infinity)
                Rectangle().fill(DS.border).frame(width: 1)
                previewColumn.frame(width: 300)
            }
            Rectangle().fill(DS.border).frame(height: 1)
            HStack(spacing: 8) {
                Text("Files stay where they are. Deleting this folder never deletes a file.").font(DS.caption).foregroundStyle(DS.text2)
                Spacer()
                Button("Cancel") { close() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Create folder" : "Save changes") { save() }
                    .buttonStyle(.primary).disabled(!canSave).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 840, height: 590)
        .background(DS.surface)
        .task(id: previewKey) { await recount() }
        .onAppear { focus = draft.isNew && draft.folder.rules.isEmpty ? .describe : .name }
    }

    // MARK: Left: name, describe, rules

    @ViewBuilder private var rulesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            PixelLabel("Name")
            field(focused: focus == .name) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(DS.text2)
                TextField("", text: $draft.folder.name, prompt: Text("e.g. Acme invoices").foregroundStyle(DS.text3))
                    .textFieldStyle(.plain).font(DS.body).focused($focus, equals: .name)
            }

            PixelLabel("Describe it — or add rules below").padding(.top, 6)
            field(focused: focus == .describe) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(DS.text2)
                TextField("", text: $draft.description, prompt: Text("e.g. invoices from gmail this year").foregroundStyle(DS.text3))
                    .textFieldStyle(.plain).font(DS.body).focused($focus, equals: .describe)
                    .onSubmit { interpret() }
                if reading {
                    ProgressView().controlSize(.small)
                    Text("reading…").font(DS.caption).foregroundStyle(DS.Tone.magic.fg)
                } else if !draft.description.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Turn into rules ↩") { interpret() }.buttonStyle(.plain).font(DS.caption).foregroundStyle(DS.Tone.magic.fg).handCursor()
                } else if let note {
                    Text(note).font(DS.caption).foregroundStyle(DS.Tone.magic.fg)
                }
            }

            HStack(spacing: 8) {
                PixelLabel("Rules · files must match")
                Menu {
                    Button("all of them") { draft.folder.matchAll = true }
                    Button("any of them") { draft.folder.matchAll = false }
                } label: { Chip(label: draft.folder.matchAll ? "all of them" : "any of them", symbol: "checkmark", menu: true) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            .padding(.top, 6)

            VStack(spacing: 0) {
                ForEach($draft.folder.rules) { $rule in
                    RuleRow(rule: $rule, sources: state.homeStats.sources) {
                        let id = rule.id
                        draft.folder.rules.removeAll { $0.id == id }
                    }
                    Rectangle().fill(DS.border).frame(height: 1)
                }
                HStack(spacing: 8) {
                    Menu {
                        ForEach(SmartRule.Field.editable) { f in
                            Button { draft.folder.rules.append(.blank(f)) } label: { Label(f.title, systemImage: f.symbol) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            Text("Add rule").font(DS.bodySM)
                        }
                        .foregroundStyle(DS.text)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().handCursor()
                    Text("kind, name, text inside, looks like, colour, came from, date, size, folder")
                        .font(DS.caption).foregroundStyle(DS.text3).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border))
        }
    }

    private func field<C: View>(focused: Bool, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DS.focus : DS.borderStrong, lineWidth: focused ? 1.5 : 1))
    }

    // MARK: Right: live preview

    @ViewBuilder private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PixelLabel("Matches right now")
                Spacer()
                if counting { ProgressView().controlSize(.small) }
                else { Text(Fmt.plural(matchCount, "file")).font(DS.body).foregroundStyle(DS.text) }
            }
            if !validRules {
                Text("Add a rule or describe the folder to see what it would hold.")
                    .font(DS.bodySM).foregroundStyle(DS.text2).padding(.top, 8)
            } else if !counting && matchCount == 0 {
                Text("Nothing matches yet. That's fine: new files that match will show up on their own.")
                    .font(DS.bodySM).foregroundStyle(DS.text2).padding(.top, 8)
            }
            ForEach(matches) { item in
                HStack(spacing: 10) {
                    Thumb(item: item, size: 30, mode: item.category == .images || item.category == .videos ? .fill : .page)
                        .frame(width: 28, height: 34).clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DS.border))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(DS.bodySM).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                        Text("\(item.rootName.isEmpty ? item.parentName : item.rootName) · \(Fmt.relative(item.activityDate))")
                            .font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface))
            }
            if matchCount > matches.count {
                Text("+ \(Fmt.count(matchCount - matches.count)) more").font(DS.bodySM).foregroundStyle(DS.text2)
            }
            Spacer(minLength: 0)
            Text("New files that match are added the moment Orca sees them.").font(DS.caption).foregroundStyle(DS.text2)
        }
        .padding(.horizontal, 16).padding(.vertical, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.surface2)
    }

    // MARK: Actions

    private func recount() async {
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        counting = true
        let rules = draft.folder.rules, all = draft.folder.matchAll, items = state.index.items
        let found = await Task.detached(priority: .userInitiated) { SmartFolder.run(rules: rules, matchAll: all, in: items) }.value
        guard !Task.isCancelled else { return }
        matchCount = found.count
        matches = Array(found.prefix(5))
        counting = false
    }

    /// "invoices from gmail this year" → Kind is PDFs-ish rules, read the same way as a search.
    private func interpret() {
        let text = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !reading else { return }
        Task { @MainActor in
            var q = QueryParser.parse(text)
            if state.prefs.smartSentences, SentenceUnderstanding.status == .available, SentenceUnderstanding.worthRefining(text) {
                reading = true
                let key = text.lowercased()
                let r: SentenceRefinement?
                if let cached = SentenceUnderstanding.cache[key] { r = cached } else { r = await SentenceUnderstanding.refine(text) }
                if let r { SentenceUnderstanding.cache[key] = r; q = QueryParser.merge(q, r, dismissed: []) }
                reading = false
            }
            let rules = SmartFolder.rules(from: q)
            guard !rules.isEmpty else { note = "couldn't read that — try adding rules"; return }
            draft.folder.rules = rules
            if draft.folder.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.folder.name = SmartFolder.suggestedName(for: text) }
            draft.description = ""
            note = "read as \(Fmt.plural(rules.count, "rule")) ↓"
        }
    }

    private func save() {
        guard canSave else { return }
        var f = draft.folder
        f.name = f.name.trimmingCharacters(in: .whitespaces)
        f.rules.removeAll { $0.query() == nil }
        if draft.isNew { state.createFolder(f) } else { state.updateFolder(f) }
        close()
    }

    private func close() { state.folderSheet = nil }
}

/// One rule: [field ▾] op [value ▾ / typed value] ×
struct RuleRow: View {
    @Binding var rule: SmartRule
    let sources: [SourceSummary]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(SmartRule.Field.editable) { f in
                    Button { if f != rule.field { let id = rule.id; rule = .blank(f); rule.id = id } } label: { Label(f.title, systemImage: f.symbol) }
                }
            } label: { Chip(label: rule.field.title, symbol: rule.field.symbol, menu: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            if !rule.field.op.isEmpty { Text(rule.field.op).font(DS.bodySM).foregroundStyle(DS.text2) }
            value
            Spacer(minLength: 0)
            IconBtn(symbol: "xmark", help: "Remove rule", action: onRemove)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    @ViewBuilder private var value: some View {
        switch rule.field {
        case .kind: optionMenu(SmartRule.kindOptions)
        case .date: optionMenu(SmartRule.dateOptions)
        case .size: optionMenu(SmartRule.sizeOptions)
        case .colour: optionMenu(SmartRule.colourOptions.map { SmartRule.Option(label: $0.capitalized, value: $0) })
        case .source:
            optionMenu([SmartRule.Option(label: "Anywhere online", value: "*")]
                       + sources.prefix(40).map { SmartRule.Option(label: "\($0.source.name) (\($0.count))", value: $0.id) })
        case .folder:
            Menu {
                ForEach(["Downloads", "Desktop", "Documents", "Pictures", "Movies", "Music"], id: \.self) { r in Button(r) { rule.value = r } }
                Divider()
                Button("Choose a Folder…") { pickFolder() }
            } label: { Chip(label: rule.valueLabel(), symbol: "folder", menu: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        case .name, .text, .looks:
            TextField("", text: Binding(get: { rule.value }, set: { rule.value = $0; if rule.field == .looks { rule.labels = nil } }),
                      prompt: Text(rule.field == .looks ? "e.g. tiger, receipt, beach" : rule.field == .name ? "e.g. invoice" : "e.g. acme").foregroundStyle(DS.text3))
                .textFieldStyle(.plain).font(DS.bodySM)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(width: 200)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.borderStrong))
        case .other:
            Chip(label: rule.valueLabel(), style: .understood)
        }
    }

    private func optionMenu(_ options: [SmartRule.Option]) -> some View {
        Menu {
            ForEach(options, id: \.value) { o in Button(o.label) { rule.value = o.value } }
        } label: { Chip(label: rule.valueLabel(sources: sources), menu: true) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.prompt = "Choose"
        guard p.runModal() == .OK, let u = p.url else { return }
        rule.value = u.path
    }
}

// MARK: - F5 · Inside a smart folder

/// Rules shown as chips under the title; × removes a rule straight away (the last one stays).
struct SmartFolderRules: View {
    @Environment(AppState.self) private var state
    let folder: SmartFolder

    var body: some View {
        let canRemove = folder.rules.count > 1
        let newCount = state.folderSeenBefore.map { seen in state.visibleItems.lazy.filter { SmartFolder.arrival($0) > seen }.count } ?? 0
        HStack(spacing: 6) {
            PixelLabel(folder.matchAll || folder.rules.count == 1 ? "Rules" : "Any of")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(folder.rules) { r in
                        Chip(label: r.summary(sources: state.homeStats.sources), symbol: r.field.symbol, style: .understood,
                             onRemove: canRemove ? { state.removeRule(r.id, from: folder.id) } : nil)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if newCount > 0 { Badge("\(newCount) new since you last looked", tone: .info) }
        }
    }
}

extension SmartFolder {
    /// "New" labels for files that arrived since the folder was last opened.
    static func newLabels(_ items: [FileItem], since: Date?) -> [String: String] {
        guard let since else { return [:] }
        var out: [String: String] = [:]
        for i in items.prefix(300) where arrival(i) > since { out[i.id] = "New · \(Fmt.relative(arrival(i)))" }
        return out
    }
}

// MARK: - F6 · Rename and delete

struct SmartFolderAlerts: ViewModifier {
    @Environment(AppState.self) private var state
    @State private var newName = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename smart folder", isPresented: Binding(get: { state.renamingFolder != nil }, set: { if !$0 { state.renamingFolder = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let f = state.renamingFolder { state.renameFolder(f.id, to: newName) }; state.renamingFolder = nil }
                Button("Cancel", role: .cancel) { state.renamingFolder = nil }
            }
            .onChange(of: state.renamingFolder?.id) { _, _ in newName = state.renamingFolder?.name ?? "" }
            .alert(state.deletingFolder.map { "Delete “\($0.name)”?" } ?? "Delete smart folder?",
                   isPresented: Binding(get: { state.deletingFolder != nil }, set: { if !$0 { state.deletingFolder = nil } })) {
                Button("Delete Folder", role: .destructive) { if let f = state.deletingFolder { state.deleteFolder(f.id) }; state.deletingFolder = nil }
                Button("Cancel", role: .cancel) { state.deletingFolder = nil }
            } message: {
                let n = state.deletingFolder.flatMap { state.folderStats[$0.id]?.count } ?? 0
                Text("The \(Fmt.plural(n, "file")) in it stay exactly where they are. Only this smart folder goes away.")
            }
    }
}
