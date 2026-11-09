import SwiftUI
import Quartz
import VisionKit

/// Double-click preview: ← → between files, a floating bar with the four things people do most
/// with this kind of file, and a Paint-style sidebar with every tool. Edits always save a copy.
struct LargePreview: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let item: FileItem
    /// Lets the snapshot hook hand in a workspace it drives.
    var preset: EditWorkspace? = nil
    @State private var ws: EditWorkspace?
    @State private var saving = false
    @State private var confirmReplace: EditToastCenter.Saved?
    @AppStorage("editSidebarVisible") private var sidebarOn = true
    private var toasts: EditToastCenter { EditToastCenter.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.border).frame(height: 1)
            HStack(spacing: 0) {
                if let ws, sidebarOn, ws.kind.hasSidebar {
                    EditSidebar(ws: ws)
                    Rectangle().fill(DS.border).frame(width: 1)
                }
                ZStack(alignment: .bottom) {
                    Group {
                        if let ws { ws.stage().padding(.bottom, 64) } else { DS.app }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 10) {
                        toastView
                        if let ws { EditBar(ws: ws, sidebarOn: $sidebarOn) }
                    }
                    .padding(.bottom, 16)
                }
                .background(DS.app)
            }
        }
        .frame(minWidth: 1000, idealWidth: 1180, minHeight: 660, idealHeight: 800)
        .background(DS.surface)
        .onAppear { if ws == nil { ws = preset ?? EditWorkspaces.make(for: item) } }
        .onChange(of: item.id) { _, _ in ws = EditWorkspaces.make(for: item) }
        .background(shortcuts)
        .confirmationDialog("Replace the original with this copy?", isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } }), presenting: confirmReplace) { s in
            Button("Replace \(s.original.name)", role: .destructive) { replace(s) }
            Button("Keep both", role: .cancel) {}
        } message: { s in
            Text("\(s.original.name) goes to the Trash, so you can still get it back. The copy takes its name.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            let editing = ws?.hasEdits ?? false
            IconBtn(symbol: "chevron.left", help: "Previous (←)") { state.previewStep(-1) }
                .keyboardShortcut(.leftArrow, modifiers: []).disabled(editing).opacity(editing ? 0.35 : 1)
            IconBtn(symbol: "chevron.right", help: "Next (→)") { state.previewStep(1) }
                .keyboardShortcut(.rightArrow, modifiers: []).disabled(editing).opacity(editing ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                Text(ws?.status ?? info).font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
            }
            Spacer()
            if editing {
                if let ws, ws.canUndo {
                    IconBtn(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { ws.undo() }
                }
                Button("Cancel") { ws?.discard() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button(saving ? (ws?.busy ?? "Saving…") : "Save copy") { save() }.buttonStyle(.primary).disabled(saving)
                    .help("Saves a new file next to the original (⌘S)")
            } else {
                Button("Open") { FileActions.open([item]) }.buttonStyle(.secondary)
                IconBtn(symbol: "folder", help: "Show in Finder") { FileActions.revealInFinder([item]) }
                Button("Done") { toasts.clear(); dismiss() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var info: String {
        [Fmt.size(item.size), Fmt.date(item.activityDate), item.dimensionsText].compactMap { $0 }.joined(separator: " · ")
    }

    private var shortcuts: some View {
        Group {
            Button("") { sidebarOn.toggle() }.keyboardShortcut("t", modifiers: .command)
            Button("") { ws?.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("") { if ws?.hasEdits == true { save() } }.keyboardShortcut("s", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }

    // MARK: Saving

    private func save() {
        guard let ws, !saving else { return }
        saving = true
        Task {
            do {
                let url = try await ws.save()
                saving = false
                let saved = EditToastCenter.Saved(original: ws.item, copy: url)
                toasts.show(saved: saved)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                   let copy = FileIndex.shared.item(url.path) ?? CopySaver.register(url, like: ws.item) {
                    state.selection = [copy.id]
                    state.previewItem = copy
                }
            } catch {
                saving = false
                toasts.show("Couldn’t save: \(error.localizedDescription)")
            }
        }
    }

    private func replace(_ s: EditToastCenter.Saved) {
        do {
            let url = try CopySaver.replaceOriginal(s.original, with: s.copy)
            toasts.show("Replaced. The old \(s.original.name) is in the Trash.")
            if let it = FileIndex.shared.item(url.path) { state.previewItem = it; state.selection = [it.id] }
        } catch {
            toasts.show("Couldn’t replace it: \(error.localizedDescription)")
        }
    }

    private func undoSave(_ s: EditToastCenter.Saved) {
        CopySaver.undo(s.copy)
        toasts.show("Copy removed")
        if item.url == s.copy, let orig = FileIndex.shared.item(s.original.path) ?? Optional(s.original) {
            state.previewItem = orig; state.selection = [orig.id]
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let s = toasts.saved {
            DarkPill {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x30A46C))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved next to the original").font(DS.bodySM)
                    Text(s.copy.lastPathComponent).font(DS.caption).foregroundStyle(DS.onDark2).lineLimit(1)
                }
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 22)
                ToastButton("Undo", strong: true) { undoSave(s) }
                ToastButton("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.copy]) }
                if s.canReplace {
                    ToastButton("Replace original…", dim: true) { confirmReplace = s }
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let m = toasts.message {
            DarkPill { Text(m).font(DS.bodySM) }.transition(.opacity)
        }
    }
}

private struct ToastButton: View {
    let title: String
    var strong = false
    var dim = false
    let action: () -> Void
    init(_ title: String, strong: Bool = false, dim: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.strong = strong; self.dim = dim; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(DS.bodySM).foregroundStyle(dim ? DS.onDark2 : .white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(strong ? 0.15 : 0)))
        }
        .buttonStyle(.plain).handCursor()
    }
}

// MARK: - Floating bar: the usual four

struct EditBar: View {
    let ws: EditWorkspace
    @Binding var sidebarOn: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ws.bar, id: \.self) { t in
                BarButton(title: ws.barTitle(t), symbol: t.symbol, selected: ws.active == t,
                          magic: t == .removeBackground && ws.active == t, enabled: ws.isAvailable(t)) { ws.select(t) }
                    .help(t.hint)
            }
            if ws.kind.hasSidebar {
                Rectangle().fill(DS.border).frame(width: 1, height: 20).padding(.horizontal, 3)
                BarButton(title: "All tools", symbol: "sidebar.left", selected: sidebarOn, magic: false, enabled: true) { sidebarOn.toggle() }
                    .help(sidebarOn ? "Hide the tools (⌘T)" : "Show all tools (⌘T)")
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.border))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

private struct BarButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let magic: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(DS.bodySM).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(magic ? DS.Tone.magic.fg : DS.text)
            .background(RoundedRectangle(cornerRadius: 8).fill(magic ? DS.Tone.magic.bg : selected ? DS.tertiary : hover ? DS.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
    }
}

// MARK: - Sidebar: every tool, the bar's four included

struct EditSidebar: View {
    let ws: EditWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ws.groups) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            PixelLabel(g.title)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                                ForEach(g.tools, id: \.self) { t in ToolTile(ws: ws, tool: t) }
                            }
                        }
                    }
                    ws.options()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(DS.surface2))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border.opacity(0.7)))
                }
                .padding(14)
            }
            .scrollIndicators(.never)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(DS.focus).frame(width: 6, height: 6)
                    Text("also in the bar").font(DS.caption).foregroundStyle(DS.text2)
                }
                if let f = ws.footer() { f }
            }
            .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 6)
        }
        .frame(width: 216)
        .background(DS.surface)
    }
}

private struct ToolTile: View {
    let ws: EditWorkspace
    let tool: ToolID
    @State private var hover = false
    var body: some View {
        let on = ws.active == tool
        let ok = ws.isAvailable(tool)
        Button { ws.select(tool) } label: {
            Image(systemName: tool.symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? DS.onBrand : DS.text)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? DS.brand : hover ? DS.hover : DS.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? .clear : DS.border, style: StrokeStyle(lineWidth: 1, dash: ok ? [] : [3, 3])))
                .overlay(alignment: .topTrailing) {
                    if ws.bar.contains(tool) && !on {
                        Circle().fill(DS.focus).frame(width: 6, height: 6).overlay(Circle().strokeBorder(DS.surface, lineWidth: 1.5)).padding(4)
                    }
                }
                .opacity(ok ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor(ok)
        .disabled(!ok)
        .onHover { hover = $0 }
        .help(ok ? "\(tool.title) — \(tool.hint)" : "\(tool.title) — coming later")
    }
}

// MARK: - Quick Look and Live Text

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
}

struct LiveTextImage: NSViewRepresentable {
    let url: URL
    let selectable: Bool
    var inset: CGFloat = 24
    func makeNSView(context: Context) -> LiveTextContainer { LiveTextContainer() }
    func updateNSView(_ v: LiveTextContainer, context: Context) { v.inset = inset; v.load(url); v.setSelectable(selectable) }
}

final class LiveTextContainer: NSView {
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private let analyzer = ImageAnalyzer()
    private var currentURL: URL?
    var inset: CGFloat = 24 { didSet { if inset != oldValue { needsLayout = true } } }

    init() {
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        overlay.autoresizingMask = [.width, .height]
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .textSelection
        imageView.addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: inset, dy: inset)
        overlay.frame = imageView.bounds
    }

    func setSelectable(_ on: Bool) {
        overlay.preferredInteractionTypes = on ? .textSelection : []
        overlay.selectableItemsHighlighted = on
    }

    func load(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        overlay.analysis = nil
        let image = NSImage(contentsOf: url)
        imageView.image = image
        guard let image else { return }
        Task { @MainActor in
            if let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text])),
               self.currentURL == url {
                self.overlay.analysis = analysis
            }
        }
    }
}
