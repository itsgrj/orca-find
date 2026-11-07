import SwiftUI
import AVKit

struct InspectorPanel: View {
    @Environment(AppState.self) private var state
    let item: FileItem
    var terms: [String] = []

    @State private var text: String?
    @State private var lastOpened: Date?
    @State private var player: AVPlayer?
    @State private var artist: String?
    @State private var album: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                preview
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(DS.body).foregroundStyle(DS.text).textSelection(.enabled).lineLimit(3)
                    Text(subtitle).font(DS.bodySM).foregroundStyle(DS.text2)
                }
                actions
                whyGroup
                if let src = item.source { sourceGroup(src) }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { textGroup(text) }
                infoGroup
            }
            .padding(14)
        }
        .card(16)
        .task(id: item.id) { await load() }
        .onDisappear { player?.pause() }
    }

    private var subtitle: String {
        var parts = [item.kindName]
        if !item.isFolder { parts.append(Fmt.size(item.size)) }
        if let d = item.dimensionsText { parts.append(d) }
        if let du = item.duration, du > 0 { parts.append(Fmt.duration(du)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var preview: some View {
        Group {
            switch item.category {
            case .videos where !item.isCloudOnly:
                VideoPlayer(player: player).onAppear { if player == nil { player = AVPlayer(url: item.url) } }
                    .frame(height: 176)
            case .music:
                ZStack(alignment: .bottomTrailing) {
                    Thumb(item: item, size: 300).frame(height: 300)
                    Button { state.player.play(item, in: state.visibleItems) } label: {
                        Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(DS.onBrand)
                            .frame(width: 44, height: 44).background(Circle().fill(DS.brand))
                    }.buttonStyle(.plain).padding(12)
                }
            case .documents:
                Thumb(item: item, size: 600, mode: .page).frame(height: 240).background(Color.white)
            case .images:
                Thumb(item: item, size: 600, mode: .fit).frame(height: 200).background(DS.surface2)
            default:
                Thumb(item: item, size: 300, mode: .fit).frame(width: 96, height: 96).frame(maxWidth: .infinity).frame(height: 150).background(DS.surface2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2) { state.previewItem = item }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if item.category == .music {
                Button("Play") { state.player.play(item, in: state.visibleItems) }.buttonStyle(.primary)
            } else if (item.category == .images || item.ext == "pdf"), item.hasText || text?.isEmpty == false {
                Button("Copy text") { state.copyTextFromSelection() }.buttonStyle(.primary)
                Button("Open") { FileActions.open([item]) }.buttonStyle(.secondary)
            } else {
                Button("Open") { item.isFolder ? state.navigate(.folder(item.path)) : FileActions.open([item]) }.buttonStyle(.primary)
            }
            Button("Show in Finder") { FileActions.revealInFinder([item]) }.buttonStyle(.secondary)
            IconBtn(symbol: "eye", help: "Quick Look (Space)") { state.toggleQuickLook() }
        }
    }

    private func sourceGroup(_ src: DownloadSource) -> some View {
        group("Downloaded from") {
            HStack(spacing: 10) {
                Image(systemName: src.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: src.color)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(src.name).font(DS.body).foregroundStyle(DS.text)
                    if let h = src.host, h != src.name { Text(h).font(DS.caption).foregroundStyle(DS.text2) }
                }
                Spacer()
                Button("All from here") { state.navigate(.downloadedFrom(src.key)) }.buttonStyle(.plainP)
            }
            ForEach(item.whereFroms.prefix(2), id: \.self) { raw in
                if let url = URL(string: raw), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) { Text(raw).font(DS.caption).lineLimit(1).truncationMode(.middle) }
                }
            }
        }
    }

    private func textGroup(_ text: String) -> some View {
        group(item.category == .images ? "Text found in image" : "Text inside") {
            Text(highlighted(String(text.prefix(700)) + (text.count > 700 ? "…" : "")))
                .font(DS.bodySM).foregroundStyle(DS.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface2))
        }
    }

    private func highlighted(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        for t in terms {
            let stem = SearchEngine.stem(t)
            guard !stem.isEmpty else { continue }
            var search = a.startIndex..<a.endIndex
            while let r = a[search].range(of: stem, options: [.caseInsensitive, .diacriticInsensitive]) {
                a[r].backgroundColor = Color(hex: 0xFFD23F, alpha: 0.45)
                a[r].underlineStyle = .single
                search = r.upperBound..<a.endIndex
            }
        }
        return a
    }

    /// S6 C: the card shows a one-line reason; the inspector tells the whole story.
    @ViewBuilder private var whyGroup: some View {
        let q = state.parsed
        let clip = SearchEngine.clipMatches(q)
        // MobileCLIP's view: the whole description, or each look phrase on its own.
        let described: [(String, MobileCLIP.Match)] = q.scene.flatMap { s in clip.scene[item.path].map { [(s, $0)] } }
            ?? q.looks.indices.compactMap { i in clip.looks[i][item.path].map { (q.looks[i].word, $0) } }
        if q.isVisual || !described.isEmpty, let seen = VisualStore.shared.get(item.path) ?? (described.isEmpty ? nil : VisualInfo()) {
            let matched = q.looks.compactMap { l in l.labels.map { ($0, seen.label($0)) }.max { $0.1 < $1.1 } }.filter { $0.1 >= 0.12 }
            let others = seen.labels.filter { w in w.value >= 0.3 && !matched.contains { $0.0 == w.name } }.prefix(3)
            if !matched.isEmpty || !q.coverColours.isEmpty || !described.isEmpty {
                group("Why it matched") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(described, id: \.0) { d in row("Looks like", "\(d.0) · \(d.1.strength.words)") }
                        ForEach(matched, id: \.0) { m in row("Looks like", "\(VisualAnalyzer.display(m.0)) · \(Int((m.1 * 100).rounded()))%") }
                        if !others.isEmpty { row("Also", others.map { VisualAnalyzer.display($0.name) }.joined(separator: " · ")) }
                        ForEach(q.coverColours, id: \.self) { c in
                            row(item.ext == "pdf" ? "Cover colour" : "Colour", "\(c) · \(Int((seen.colour(c) * 100).rounded()))%")
                        }
                        if item.ext == "pdf" { row("Checked", "page 1") }
                        row("Found by", item.ext == "pdf" ? "looking at the cover" : "looking at the picture")
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface2))
                }
            }
        }
    }

    private var infoGroup: some View {
        group("Information") {
            if let artist { row("Artist", artist) }
            if let album { row("Album", album) }
            if let d = item.dimensionsText { row(item.category == .videos ? "Resolution" : "Dimensions", d) }
            if let du = item.duration, du > 0 { row("Duration", Fmt.duration(du)) }
            if let cam = item.camera { row("Camera", cam) }
            row("Created", Fmt.date(item.created))
            row("Modified", Fmt.date(item.modified))
            if let a = item.added { row("Added", Fmt.date(a)) }
            row("Last opened", lastOpened.map { Fmt.date($0) } ?? "Never")
            row("Where", (item.parentPath as NSString).abbreviatingWithTildeInPath)
            if item.isCloudOnly { row("iCloud", "Stored in iCloud only") }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PixelLabel(title)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).font(DS.bodySM).foregroundStyle(DS.text2).frame(width: 84, alignment: .leading)
            Text(v).font(DS.bodySM).foregroundStyle(DS.text).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        let path = item.path, url = item.url, isMusic = item.category == .music
        let (t, used) = await Task.detached(priority: .userInitiated) { (Database.shared.text(for: path), MetadataReader.lastUsedDate(url)) }.value
        text = t
        lastOpened = used
        if isMusic {
            let asset = AVURLAsset(url: url)
            if let md = try? await asset.load(.commonMetadata) {
                if let i = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierArtist).first { artist = try? await i.load(.stringValue) }
                if let i = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierAlbumName).first { album = try? await i.load(.stringValue) }
            }
        }
    }
}
