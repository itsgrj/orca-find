import AppKit
import Quartz

/// Drives the native macOS Quick Look panel (Space), with arrow-key navigation.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    private(set) var items: [FileItem] = []

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false) }

    func toggle(items: [FileItem], index: Int) {
        if isVisible { close(); return }
        guard !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.items = items
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.currentPreviewItemIndex = max(0, min(index, items.count - 1))
    }

    func update(items: [FileItem], index: Int) {
        guard isVisible, let panel = QLPreviewPanel.shared() else { return }
        if items.map(\.id) != self.items.map(\.id) {
            self.items = items
            panel.reloadData()
        }
        panel.currentPreviewItemIndex = max(0, min(index, items.count - 1))
    }

    var currentIndex: Int { QLPreviewPanel.shared()?.currentPreviewItemIndex ?? 0 }

    func close() {
        if isVisible { QLPreviewPanel.shared()?.orderOut(nil) }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard items.indices.contains(index) else { return nil }
            return items[index].url as NSURL
        }
    }
}
