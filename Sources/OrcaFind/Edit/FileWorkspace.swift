import SwiftUI
import AppKit

/// Files Orca can't change (Word documents, archives, code…): Quick Look plus a bar with
/// Zip, Share, Rename and Copy path. No sidebar, because there's nothing to edit.
@MainActor
@Observable
final class FileWorkspace: EditWorkspace {
    let item: FileItem
    var kind: EditKind { .other }
    let bar: [ToolID] = [.zip, .share, .rename, .copyPath]
    var groups: [ToolGroup] { [] }
    var active: ToolID? { nil }
    var hasEdits: Bool { false }
    var status: String? { nil }
    private(set) var busy: String?
    var canUndo: Bool { false }
    var renaming = false
    var newName = ""

    init(item: FileItem) { self.item = item }

    func select(_ tool: ToolID) {
        switch tool {
        case .zip: zip()
        case .share: share()
        case .rename: newName = item.name; renaming = true
        case .copyPath:
            FileActions.copyPath([item])
            EditToastCenter.shared.show("Path copied · \(item.shortPath)")
        default: break
        }
    }

    private func zip() {
        guard busy == nil else { return }
        let dest = CopySaver.destination(near: item.url, suffix: nil, ext: "zip")
        busy = "Zipping…"
        let src = item.url, original = item
        Task {
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, dest.path]
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
            }.value
            busy = nil
            if ok {
                CopySaver.register(dest, like: original)
                EditToastCenter.shared.show(saved: .init(original: original, copy: dest))
            } else {
                EditToastCenter.shared.show("Couldn’t zip \(original.name)")
            }
        }
    }

    private func share() {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [item.url])
        let r = NSRect(x: view.bounds.midX - 1, y: 40, width: 2, height: 2)
        picker.show(relativeTo: r, of: view, preferredEdge: .maxY)
    }

    func rename() -> FileItem? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = false
        guard !name.isEmpty, name != item.name, !name.contains("/") else { return nil }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            EditToastCenter.shared.show("There’s already a file called \(name) there"); return nil
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            FileIndex.shared.remove(paths: [item.path])
            let renamed = CopySaver.register(target, like: item)
            EditToastCenter.shared.show("Renamed to \(name)")
            return renamed
        } catch {
            EditToastCenter.shared.show("Couldn’t rename: \(error.localizedDescription)")
            return nil
        }
    }

    func undo() {}
    func discard() {}
    func save() async throws -> URL { item.url }
    func stage() -> AnyView { AnyView(FileStage(ws: self)) }
    func options() -> AnyView { AnyView(EmptyView()) }
}

private struct FileStage: View {
    @Bindable var ws: FileWorkspace
    @Environment(AppState.self) private var state
    var body: some View {
        ZStack(alignment: .top) {
            QuickLookView(url: ws.item.url)
            if let b = ws.busy {
                DarkPill { ProgressView().controlSize(.small).tint(.white); Text(b).font(DS.bodySM) }.padding(.top, 18)
            }
        }
        .alert("Rename", isPresented: $ws.renaming) {
            TextField("Name", text: $ws.newName)
            Button("Rename") { if let r = ws.rename() { state.previewItem = r; state.selection = [r.id] } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new name for \(ws.item.name)")
        }
    }
}
