import SwiftUI
import Quartz
import VisionKit

/// Double-click preview: ← → between files; images get Live Text so you can select and copy words.
struct LargePreview: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let item: FileItem
    @State private var selectText = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconBtn(symbol: "chevron.left", help: "Previous (←)") { state.previewStep(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                IconBtn(symbol: "chevron.right", help: "Next (→)") { state.previewStep(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                    Text([Fmt.size(item.size), Fmt.date(item.activityDate), item.dimensionsText].compactMap { $0 }.joined(separator: " · "))
                        .font(DS.caption).foregroundStyle(DS.text2)
                }
                Spacer()
                if item.category == .images {
                    Button { selectText.toggle() } label: { Chip(label: "Select text", symbol: "text.viewfinder", style: selectText ? .selected : .normal) }
                        .buttonStyle(.plain).help("Select words right inside the image")
                    Button("Copy text") { state.selection = [item.id]; state.copyTextFromSelection() }.buttonStyle(.secondary)
                }
                Button("Open") { FileActions.open([item]) }.buttonStyle(.secondary)
                IconBtn(symbol: "folder", help: "Show in Finder") { FileActions.revealInFinder([item]) }
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(DS.border).frame(height: 1)
            Group {
                if item.category == .images && !item.isCloudOnly {
                    LiveTextImage(url: item.url, selectable: selectText)
                } else {
                    QuickLookView(url: item.url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.app)
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 560, idealHeight: 700)
        .background(DS.surface)
    }
}

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
    func makeNSView(context: Context) -> LiveTextContainer { LiveTextContainer() }
    func updateNSView(_ v: LiveTextContainer, context: Context) { v.load(url); v.setSelectable(selectable) }
}

final class LiveTextContainer: NSView {
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private let analyzer = ImageAnalyzer()
    private var currentURL: URL?

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
        imageView.frame = bounds.insetBy(dx: 24, dy: 24)
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
