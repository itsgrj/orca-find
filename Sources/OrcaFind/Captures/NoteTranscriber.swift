import Foundation
import Speech
import AVFoundation

/// After a voice note is saved, Orca listens to the whole recording once more and quietly replaces the live words.
/// Live recognition can drop parts of what was said (it restarts after pauses); a pass over the full recording
/// doesn't, and it gets names and unusual words right more often. Order of preference:
/// the downloaded English model (most accurate) → Apple's newer recognizer (macOS 26) → Apple's older one.
/// Nothing about this is shown in the UI — the note just reads right.
@MainActor
enum NoteTranscriber {
    enum Source: String { case apple, model }

    // MARK: Listening

    /// The best words for a recording, or nil to keep what the note already says.
    static func listen(_ url: URL, live: String) async -> (text: String, source: Source)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let prefs = Preferences.shared
        let locale = prefs.voiceLocale, onDevice = prefs.voiceOnDevice
        if SpeechModel.shared.isReady, SpeechModel.languageIsEnglish {
            do {
                let text = clean(try await SpeechModel.shared.transcribe(url))
                if !text.isEmpty {
                    // A mumble heard as a swear word that Apple didn't hear: trust Apple for this note.
                    guard swears(in: text).subtracting(swears(in: live)).isEmpty else {
                        if let a = await apple(url, locale: locale, onDevice: onDevice),
                           swears(in: a).subtracting(swears(in: live)).isEmpty { return (a, .apple) }
                        return nil
                    }
                    return (text, .model)
                }
            } catch {
                NSLog("OrcaFind: speech model couldn’t read \(url.lastPathComponent): \(error)")
            }
        }
        if let a = await apple(url, locale: locale, onDevice: onDevice) { return (a, .apple) }
        return nil
    }

    /// Apple's recognizers over the whole file: the newer one on macOS 26, else the one live capture uses.
    static func apple(_ url: URL, locale: String, onDevice: Bool) async -> String? {
        if #available(macOS 26.0, *), let t = await analyzer(url, locale: locale) {
            let c = clean(t)
            if !c.isEmpty { return c }
        }
        guard let t = await CaptureRecorder.transcribeFile(url, locale: locale, onDevice: onDevice) else { return nil }
        let c = clean(t)
        return c.isEmpty ? nil : c
    }

    @available(macOS 26.0, *)
    nonisolated static func analyzer(_ url: URL, locale: String) async -> String? {
        do {
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else { return nil }
            let transcriber = SpeechTranscriber(locale: loc, preset: .transcription)
            // macOS fetches its own speech files the first time (shared with dictation; free, on this Mac).
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file = try AVAudioFile(forReading: url)
            let collect = Task { () -> String in
                var parts: [String] = []
                for try await r in transcriber.results where r.isFinal { parts.append(String(r.text.characters)) }
                return parts.joined(separator: " ")
            }
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            return try await collect.value
        } catch {
            NSLog("OrcaFind: Apple speech couldn’t read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Keep the new words only if they aren't clearly worse: a pass that came back with far fewer words
    /// than the live transcript probably failed part-way, so the live words stay.
    static func accept(_ new: String, over live: String) -> Bool {
        let n = wordCount(new), l = wordCount(live)
        guard n > 0 else { return false }
        if new == live { return false }
        return Double(n) >= Double(l) * 0.7
    }

    // MARK: Tidying the words

    /// Drops "uh", "um" and friends and fixes the spacing and capitals they leave behind.
    nonisolated static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        // "a, um, feature" → "a feature": the filler goes with the commas around it; a full stop after it stays.
        t = t.replacingOccurrences(of: #"(?i),?\s*(?<![\w'’-])(?:uh+|um+|uhm|erm|hmm+)(?![\w'’-]),?"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #",(\s*,)+"#, with: ",", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([.!?])\s*,"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:")))
        // A capital at the start and after each full stop.
        var out = "", upNext = true
        for ch in t {
            if upNext, ch.isLetter { out.append(contentsOf: ch.uppercased()); upNext = false; continue }
            if ".!?".contains(ch) { upNext = true } else if !ch.isWhitespace { upNext = false }
            out.append(ch)
        }
        return out
    }

    private static let swearRoots = ["fuck", "shit", "bitch", "cunt", "asshole", "bastard", "dickhead", "motherf"]

    nonisolated static func swears(in s: String) -> Set<String> {
        let words = s.lowercased().split { !$0.isLetter }.map(String.init)
        return Set(words.filter { w in swearRoots.contains { w.hasPrefix($0) } })
    }

    nonisolated static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    // MARK: Putting the words on a capture

    /// Sets the note and files the capture by what was actually said (collection, tags; a reminder only
    /// when `reminders` is on and none was set). Returns the reminder's task text when one was newly found.
    @discardableResult
    static func apply(_ text: String, _ source: Source, to c: inout Capture, reminders: Bool) -> String? {
        c.note = text
        c.noteSource = source.rawValue
        let lib = CaptureLibrary.shared
        let again = SpokenIntent.parse(text, existing: lib.collections.map(\.name), existingTags: lib.tagNames, now: c.created)
        if c.collection == nil { c.collection = again.collection; c.collectionPhrase = again.collectionPhrase }
        for t in again.tags { c.addTag(t, origin: "said") }
        for t in CaptureTags.mentioned(in: text, existing: lib.tagNames) { c.addTag(t, origin: "orca") }
        if reminders, c.reminderDate == nil, let due = again.reminderDate {
            c.reminderDate = due
            c.reminderPhrase = again.reminderPhrase
            return again.reminderTask ?? ""
        }
        return nil
    }

    // MARK: Earlier notes

    /// Voice notes that a better pass could still improve.
    static func improvable(withModel: Bool) -> [Capture] {
        CaptureLibrary.shared.items.filter { c in
            c.hasAudio && !c.noteTyped && (withModel ? c.noteSource != Source.model.rawValue : c.noteSource == nil)
        }
    }

    /// Once, quietly, a while after launch: re-listen to voice notes saved before this existed, so notes that
    /// lost words (or a "put it in…" instruction) get them back. No reminders are created for old notes.
    static func startupPass() {
        let key = "earlierNotesListened.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            await EarlierNotes.shared.run(withModel: false)
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}

/// "Improve 24 notes" in Settings, and the one-time quiet pass at launch.
@MainActor
@Observable
final class EarlierNotes {
    static let shared = EarlierNotes()
    private(set) var running = false
    private(set) var done = 0
    private(set) var total = 0

    func run(withModel: Bool) async {
        guard !running else { return }
        let list = NoteTranscriber.improvable(withModel: withModel)
        guard !list.isEmpty else { return }
        running = true; done = 0; total = list.count
        defer { running = false }
        for old in list {
            guard var c = CaptureLibrary.shared.capture(old.id), !c.noteTyped else { done += 1; continue }
            if let (text, source) = await NoteTranscriber.listen(c.audioURL, live: c.note) {
                if NoteTranscriber.accept(text, over: c.note) {
                    NoteTranscriber.apply(text, source, to: &c, reminders: false)
                } else {
                    c.noteSource = source.rawValue   // checked; the words were already right
                }
                CaptureLibrary.shared.update(c)
            }
            done += 1
        }
    }
}
