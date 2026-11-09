import SwiftUI
import AppKit

// Plain words only: people see what gets better, how big the download is and that it stays on this Mac —
// never the name of a model or how it works.

/// "More accurate voice notes" + "Clean up background noise". Shown in Settings › Captures and
/// Settings › Search & Voice; both read the same state, so they always agree.
struct VoiceNotesSettings: View {
    @Environment(AppState.self) private var state
    private var model: SpeechModel { SpeechModel.shared }
    private var earlier: EarlierNotes { EarlierNotes.shared }
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var p = state.prefs
        VStack(alignment: .leading, spacing: 18) {
            if SpeechModel.isSupported {
                section("Voice notes") {
                    modelRow
                    let n = model.isReady ? NoteTranscriber.improvable(withModel: true).count : 0
                    if model.isReady && (n > 0 || earlier.running) {
                        Rectangle().fill(DS.border).frame(height: 1)
                        earlierRow(n)
                    }
                }
            }
            section("Recording") {
                row("Clean up background noise", sub: "Makes your recordings clearer by cutting out fan, keyboard and room noise.") {
                    Toggle("", isOn: $p.cleanUpNoise).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .confirmationDialog("Remove the download?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove() }
        } message: {
            Text("Your voice notes keep the words they have. New ones will still be checked, just less accurately.")
        }
    }

    // MARK: Rows

    @ViewBuilder private var modelRow: some View {
        let english = SpeechModel.languageIsEnglish
        HStack(alignment: .top, spacing: 12) {
            VoiceNotesIcon()
            VStack(alignment: .leading, spacing: 3) {
                Text("More accurate voice notes").font(DS.body).foregroundStyle(DS.text)
                Text("After you finish talking, Orca listens to your note once more and fixes any words it misheard. Works offline; your voice never leaves this Mac.")
                    .font(DS.bodySM).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                Group {
                    if !english {
                        Text("Available in English for now. Your voice language is \(Self.languageName).")
                    } else if case .failed(let why) = model.state {
                        Text(why).foregroundStyle(DS.critical)
                    } else if !model.isReady && !model.isBusy && !SpeechModel.hasRoom {
                        Text("Needs \(SpeechModel.downloadLabel) free. This Mac has \(Self.mb(SpeechModel.freeBytes)) free.")
                    } else {
                        Text(model.isReady ? "Uses \(SpeechModel.downloadLabel) on this Mac" : "One-time download · \(SpeechModel.downloadLabel)")
                    }
                }
                .font(DS.caption).foregroundStyle(DS.text2)
            }
            .frame(maxWidth: 360, alignment: .leading)
            Spacer(minLength: 12)
            modelAction(english: english)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder private func modelAction(english: Bool) -> some View {
        switch model.state {
        case .ready:
            HStack(spacing: 8) {
                Badge("Ready ✓", tone: .success)
                Button("Remove") { confirmRemove = true }.buttonStyle(.plainP)
            }
        case .downloading(let f):
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Text(model.progressText).font(DS.caption).foregroundStyle(DS.text2)
                    Button("Cancel") { model.cancel() }.buttonStyle(.plainP)
                }
                ProgressView(value: f).progressViewStyle(.linear).frame(width: 190)
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.progressText).font(DS.caption).foregroundStyle(DS.text2)
            }
        case .failed:
            Button("Resume") { model.download() }.buttonStyle(.primary).disabled(!english)
        case .notInstalled:
            if english && !SpeechModel.hasRoom {
                Button("Storage Settings…") { Self.openStorage() }.buttonStyle(.secondary)
            } else {
                Button("Download") { model.download() }.buttonStyle(.primary).disabled(!english).opacity(english ? 1 : 0.45)
            }
        }
    }

    private func earlierRow(_ n: Int) -> some View {
        row("Earlier voice notes", sub: earlier.running ? "Improving \(earlier.done) of \(earlier.total)…"
                                                       : "\(n) \(n == 1 ? "note was" : "notes were") saved before this was turned on.") {
            if earlier.running { ProgressView().controlSize(.small) }
            else { Button("Improve \(n) \(n == 1 ? "note" : "notes")") { Task { await EarlierNotes.shared.run(withModel: true) } }.buttonStyle(.secondary) }
        }
    }

    // MARK: Pieces

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PixelLabel(title)
            VStack(spacing: 0) { content() }.background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
        }
    }

    private func row<R: View>(_ title: String, sub: String, @ViewBuilder _ right: () -> R) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.body).foregroundStyle(DS.text)
                Text(sub).font(DS.bodySM).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            right()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    static var languageName: String {
        let id = Preferences.shared.voiceLocale
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    static func mb(_ bytes: Int64) -> String { "\(max(0, bytes) / 1_000_000) MB" }

    static func openStorage() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(u) }
    }
}

struct VoiceNotesIcon: View {
    var tile: Color = DS.Tone.magic.bg
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DS.Tone.magic.fg)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tile))
    }
}

/// The one-time tip at the top of Captures. Polite by design: it waits for a few voice notes, and
/// "Not now" means not now — hidden for at least two weeks and five more voice notes, so switching tabs
/// and coming back never brings it back. A second "Not now" hides it for good (Settings still has it).
struct VoiceNotesTip: View {
    @Environment(CaptureLibrary.self) private var library
    private var model: SpeechModel { SpeechModel.shared }
    @State private var hidden = false
    @State private var startedHere = false
    /// Snapshots only: show it regardless of the rules.
    var preview = false

    private static let d = UserDefaults.standard
    private static let goneKey = "voiceTip.gone", dismissalsKey = "voiceTip.dismissals"
    private static let dismissedAtKey = "voiceTip.dismissedAt", notesAtKey = "voiceTip.notesAtDismiss"
    static let firstAfter = 5, againAfterNotes = 5
    static let againAfter: TimeInterval = 14 * 86_400

    private var voiceNotes: Int { library.items.filter { $0.audioSeconds > 0 }.count }

    private var shouldShow: Bool {
        if preview { return true }
        guard !hidden, SpeechModel.isSupported, SpeechModel.languageIsEnglish else { return false }
        // Once a download starts here, the tip stays as its progress line until it's done.
        if startedHere { return !model.isReady }
        guard model.state == .notInstalled, SpeechModel.hasRoom else { return false }
        return Self.isDue(voiceNotes: voiceNotes)
    }

    static func isDue(voiceNotes: Int, now: Date = Date()) -> Bool {
        guard !d.bool(forKey: goneKey), voiceNotes >= firstAfter else { return false }
        if let last = d.object(forKey: dismissedAtKey) as? Date {
            return now.timeIntervalSince(last) >= againAfter && voiceNotes >= d.integer(forKey: notesAtKey) + againAfterNotes
        }
        return true
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 12) {
                VoiceNotesIcon(tile: DS.surface)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Make your voice notes more accurate").font(DS.body).foregroundStyle(DS.Tone.magic.fg)
                    Text(subtitle).font(DS.bodySM).foregroundStyle(DS.Tone.magic.fg.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                actions
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Tone.magic.bg))
            .transition(.opacity)
        }
    }

    private var subtitle: String {
        switch model.state {
        case .downloading, .preparing: return model.progressText
        case .failed(let why): return why
        default: return "A one-time download (\(SpeechModel.downloadLabel)). After that, Orca double-checks what you said and fixes misheard words. Works offline."
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.state {
        case .downloading(let f):
            HStack(spacing: 10) {
                ProgressView(value: f).progressViewStyle(.linear).frame(width: 160)
                Button("Cancel") { model.cancel(); startedHere = false }.buttonStyle(.plainP)
            }
        case .preparing:
            ProgressView().controlSize(.small)
        case .failed:
            HStack(spacing: 8) {
                Button("Not now") { notNow() }.buttonStyle(.plainP)
                Button("Resume") { model.download() }.buttonStyle(.primary)
            }
        default:
            HStack(spacing: 8) {
                Button("Not now") { notNow() }.buttonStyle(.plainP)
                Button("Download") { startedHere = true; model.download() }.buttonStyle(.primary)
            }
        }
    }

    private func notNow() {
        let n = Self.d.integer(forKey: Self.dismissalsKey) + 1
        Self.d.set(n, forKey: Self.dismissalsKey)
        if n >= 2 { Self.d.set(true, forKey: Self.goneKey) }
        Self.d.set(Date(), forKey: Self.dismissedAtKey)
        Self.d.set(voiceNotes, forKey: Self.notesAtKey)
        if model.isBusy { model.cancel() }
        startedHere = false
        withAnimation(.easeOut(duration: 0.2)) { hidden = true }
    }
}
