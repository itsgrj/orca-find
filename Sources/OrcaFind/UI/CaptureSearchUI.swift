import SwiftUI

/// V7 — captures inside the main search: the best match large, with the sentence you said that matched,
/// then a short row of other close ones. Files follow underneath as before.
struct CaptureSearchSection: View {
    @Environment(AppState.self) private var state
    let hits: [Capture]
    let terms: [String]
    let width: CGFloat

    var body: some View {
        if let best = hits.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    PixelLabel("From your captures")
                    Spacer()
                    Button {
                        state.capturesFolder = nil
                        state.capturesTag = nil
                        state.capturesQuery = terms.joined(separator: " ")
                        state.navigate(.captures)
                    } label: {
                        Text(hits.count > 1 ? "See all in Captures →" : "Open Captures →").font(DS.caption).foregroundStyle(DS.link)
                    }
                    .buttonStyle(.plain).handCursor()
                }
                BestCaptureCard(capture: best, terms: terms, wide: width > 760)
                let rest = Array(hits.dropFirst().prefix(width > 1100 ? 4 : 3))
                if !rest.isEmpty {
                    Text("Also close").font(DS.bodySM).foregroundStyle(DS.text2).padding(.top, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: width > 1100 ? 4 : 3), alignment: .leading, spacing: 16) {
                        ForEach(rest) { c in
                            VStack(alignment: .leading, spacing: 6) {
                                CaptureCard(capture: c)
                                    .onTapGesture { state.navigate(.capture(c.id)) }
                                    .contextMenu { CaptureMenu(capture: c) }
                                if let why = CaptureSearch.why(c, terms: terms) {
                                    HStack(alignment: .top, spacing: 5) {
                                        Image(systemName: "sparkle").font(.system(size: 9)).padding(.top, 2)
                                        Text(Self.short(why)).font(DS.caption).lineLimit(2)
                                    }
                                    .foregroundStyle(DS.Tone.magic.fg)
                                    .padding(.horizontal, 4)
                                }
                            }
                        }
                    }
                }
                Rectangle().fill(DS.border).frame(height: 1).padding(.top, 8)
            }
        }
    }

    static func short(_ w: CaptureSearch.Why) -> String {
        switch w {
        case .said(let s): return "You said “\(s.trimmingCharacters(in: CharacterSet(charactersIn: "…")))”"
        case .title(let s): return "Title: \(s)"
        case .picture(let s): return "In the picture: “\(s)”"
        case .collection(let c): return "In \(c)"
        case .tag(let t): return "Tagged #\(t)"
        case .link(let l): return "Link: \(l)"
        }
    }
}

struct BestCaptureCard: View {
    @Environment(AppState.self) private var state
    let capture: Capture
    let terms: [String]
    var wide = true
    @State private var hovering = false

    var body: some View {
        let c = capture
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 22)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            ZStack(alignment: .topLeading) {
                CaptureThumb(id: c.id, maxPixel: 1000, fit: true)
                if hovering, c.hasClip { LoopingClipView(url: c.clipURL).allowsHitTesting(false) }
                if let s = c.clipSeconds, s > 0 {
                    Label(CaptureStripView.clock(s), systemImage: "play.fill").font(DS.caption).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.7))).padding(8)
                }
            }
            .frame(width: wide ? 360 : nil, height: 230)
            .frame(maxWidth: wide ? 360 : .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text(c.title.isEmpty ? "Capture" : c.title).font(DS.headingMD).foregroundStyle(DS.text).lineLimit(2)
                Text(meta).font(DS.caption).foregroundStyle(DS.text2)
                if let why = CaptureSearch.why(c, terms: terms) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Why it matched", systemImage: "sparkle").font(DS.caption).foregroundStyle(DS.Tone.magic.fg)
                        whyText(why).font(DS.bodySM).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.Tone.magic.bg))
                }
                if !c.tagList.isEmpty {
                    Text(c.tagList.map { "#" + $0 }.joined(separator: "  ")).font(DS.caption).foregroundStyle(DS.text2)
                }
                HStack(spacing: 8) {
                    Button("Open") { state.navigate(.capture(c.id)) }.buttonStyle(.primary)
                    if let link = c.links.first, let url = URL(string: link) {
                        Button(c.pageURL != nil ? "Open on \(c.sourceLabel)" : "Open link") { NSWorkspace.shared.open(url) }.buttonStyle(.secondary)
                    }
                    Button("Copy for AI") { CaptureActions.copyForAI(c) }.buttonStyle(.secondary)
                        .help("Copies the picture with what you said, the links and the text in it — paste into Claude or any chat")
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .card(16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovering ? DS.borderStrong : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { state.navigate(.capture(c.id)) }
        .contextMenu { CaptureMenu(capture: c) }
    }

    private var meta: String {
        var parts = ["Saved \(Self.date(capture.created))", capture.sourceLabel]
        if let col = capture.collection { parts.append("in \(col)") }
        if capture.links.count > 0 { parts.append(Fmt.plural(capture.links.count, "link")) }
        if let s = capture.clipSeconds, s > 0 { parts.append("clip \(CaptureStripView.clock(s))") }
        return parts.joined(separator: " · ")
    }

    private func whyText(_ w: CaptureSearch.Why) -> Text {
        switch w {
        case .said(let s): return Text("You said: “") + Text(CaptureSearch.highlighted(s, terms)) + Text("”")
        case .title(let s): return Text("Title: ") + Text(CaptureSearch.highlighted(s, terms))
        case .picture(let s): return Text("In the picture: “") + Text(CaptureSearch.highlighted(s, terms)) + Text("”")
        case .collection(let c): return Text("Saved in \(c)")
        case .tag(let t): return Text("Tagged #\(t)")
        case .link(let l): return Text("Link: \(l)")
        }
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: d)
    }
}
