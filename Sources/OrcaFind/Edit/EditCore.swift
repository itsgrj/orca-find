import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The editing layer behind the large preview: a floating bar with the four most-used actions
// for the kind of file, and a Paint-style sidebar with every tool (the bar's four included).
// Edits are never written over the original: every save makes a new copy next to it.

// MARK: - File kinds

enum EditKind: String {
    case photo, screenshot, pdf, video, audio, other

    static func of(_ item: FileItem) -> EditKind {
        if item.isFolder || item.isCloudOnly || item.isPackage { return .other }
        switch item.category {
        case .images:
            // Vector and odd formats can't be edited as pixels.
            if ["svg", "svgz", "ico", "icns", "eps", "ai", "psd"].contains(item.ext) { return .other }
            return item.isScreenshot ? .screenshot : .photo
        case .videos: return .video
        case .music: return .audio
        case .documents: return item.ext == "pdf" ? .pdf : .other
        default: return .other
        }
    }

    /// Whether this kind gets the sidebar at all (plain files only get the bar).
    var hasSidebar: Bool { self != .other }
}

// MARK: - Tools

/// Every tool across every kind of file. A workspace decides which ones it offers and what they do.
enum ToolID: String, CaseIterable, Hashable {
    // Pictures
    case removeBackground, selectArea, crop, eraseObject
    case pen, highlighter, text, arrow, shape, redact, pipette, zoom
    case enhance, adjust, rotate, flip
    case convert, resize, compress, stripLocation
    case copyText, translate
    // PDF
    case rotatePages, deletePages, reorderPages, extractPages, splitPDF, insertPages, insertBlank, cropMargins
    case mergePDFs, photosToPDF, scanFromIPhone
    case pdfCopyText, makeSearchable, findInPDF, highlight, textNote, fillForms, sign, pdfTranslate
    case compressPDF, pdfToImages, pdfToText, password, removeDetails, blackAndWhite
    // Video & audio
    case trim, saveFrame, cropVideo, rotateVideo, saveAsMP4, makeGIF, extractAudio, compressVideo
    case transcribe, resizeVideo, flipVideo, muteVideo, stripVideoLocation
    case trimAudio, convertAudio, compressAudio, transcribeAudio
    // Any file
    case zip, share, rename, copyPath

    var title: String {
        switch self {
        case .removeBackground: return "Remove background"
        case .selectArea: return "Select area"
        case .crop: return "Crop"
        case .eraseObject: return "Erase an object"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .shape: return "Box"
        case .redact: return "Redact"
        case .pipette: return "Pick a colour"
        case .zoom: return "Zoom"
        case .enhance: return "Enhance"
        case .adjust: return "Adjust"
        case .rotate: return "Rotate"
        case .flip: return "Flip"
        case .convert: return "Convert"
        case .resize: return "Resize"
        case .compress: return "Compress"
        case .stripLocation: return "Remove location"
        case .copyText: return "Copy text"
        case .translate: return "Translate"
        case .rotatePages: return "Rotate pages"
        case .deletePages: return "Delete pages"
        case .reorderPages: return "Reorder pages"
        case .extractPages: return "Extract pages"
        case .splitPDF: return "Split"
        case .insertPages: return "Insert pages"
        case .insertBlank: return "Blank page"
        case .cropMargins: return "Crop margins"
        case .mergePDFs: return "Merge"
        case .photosToPDF: return "Photos to PDF"
        case .scanFromIPhone: return "Scan from iPhone"
        case .pdfCopyText: return "Copy text"
        case .makeSearchable: return "Make searchable"
        case .findInPDF: return "Find"
        case .highlight: return "Highlight"
        case .textNote: return "Text box"
        case .fillForms: return "Fill in forms"
        case .sign: return "Sign"
        case .pdfTranslate: return "Translate"
        case .compressPDF: return "Compress"
        case .pdfToImages: return "Save as images"
        case .pdfToText: return "Save as text"
        case .password: return "Password"
        case .removeDetails: return "Remove details"
        case .blackAndWhite: return "Black & white"
        case .trim: return "Trim"
        case .saveFrame: return "Save this frame"
        case .cropVideo: return "Crop"
        case .rotateVideo: return "Rotate"
        case .saveAsMP4: return "Save as MP4"
        case .makeGIF: return "Make a GIF"
        case .extractAudio: return "Pull out audio"
        case .compressVideo: return "Compress"
        case .transcribe: return "Transcribe"
        case .resizeVideo: return "Resize"
        case .flipVideo: return "Flip"
        case .muteVideo: return "Mute"
        case .stripVideoLocation: return "Remove location"
        case .trimAudio: return "Trim"
        case .convertAudio: return "Convert"
        case .compressAudio: return "Compress"
        case .transcribeAudio: return "Transcribe"
        case .zip: return "Zip"
        case .share: return "Share"
        case .rename: return "Rename"
        case .copyPath: return "Copy path"
        }
    }

    var symbol: String {
        switch self {
        case .removeBackground: return "person.and.background.dotted"
        case .selectArea: return "rectangle.dashed"
        case .crop, .cropVideo, .cropMargins: return "crop"
        case .eraseObject: return "eraser"
        case .pen: return "pencil.tip"
        case .highlighter, .highlight: return "highlighter"
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .shape: return "square"
        case .redact: return "squareshape.split.3x3"
        case .pipette: return "eyedropper"
        case .zoom: return "plus.magnifyingglass"
        case .enhance: return "wand.and.stars"
        case .adjust: return "slider.horizontal.3"
        case .rotate, .rotateVideo: return "rotate.left"
        case .flip, .flipVideo: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .convert, .saveAsMP4, .convertAudio: return "arrow.left.arrow.right"
        case .resize, .resizeVideo: return "arrow.up.left.and.arrow.down.right"
        case .compress, .compressPDF, .compressVideo, .compressAudio: return "arrow.down.right.and.arrow.up.left"
        case .stripLocation, .stripVideoLocation: return "location.slash"
        case .copyText, .pdfCopyText: return "text.viewfinder"
        case .translate, .pdfTranslate: return "translate"
        case .rotatePages: return "rotate.right"
        case .deletePages: return "trash"
        case .reorderPages: return "arrow.up.arrow.down"
        case .extractPages: return "rectangle.portrait.and.arrow.right"
        case .splitPDF: return "scissors"
        case .insertPages: return "plus.rectangle.on.rectangle"
        case .insertBlank: return "doc.badge.plus"
        case .mergePDFs: return "square.stack.3d.up"
        case .photosToPDF: return "photo.on.rectangle"
        case .scanFromIPhone: return "iphone"
        case .makeSearchable: return "doc.text.magnifyingglass"
        case .findInPDF: return "magnifyingglass"
        case .textNote: return "character.textbox"
        case .fillForms: return "checklist"
        case .sign: return "signature"
        case .pdfToImages: return "photo.stack"
        case .pdfToText: return "doc.plaintext"
        case .password: return "lock"
        case .removeDetails: return "eye.slash"
        case .blackAndWhite: return "circle.lefthalf.filled"
        case .trim, .trimAudio: return "scissors"
        case .saveFrame: return "photo"
        case .makeGIF: return "square.stack.3d.forward.dottedline"
        case .extractAudio: return "waveform"
        case .transcribe, .transcribeAudio: return "text.bubble"
        case .muteVideo: return "speaker.slash"
        case .zip: return "archivebox"
        case .share: return "square.and.arrow.up"
        case .rename: return "pencil.line"
        case .copyPath: return "doc.on.doc"
        }
    }

    /// One line that explains the tool (tooltips and the options box).
    var hint: String {
        switch self {
        case .removeBackground: return "Keep the subject, drop the rest"
        case .selectArea: return "Drag a box, then crop, copy or redact it"
        case .crop: return "Shape, straighten, trim the edges"
        case .eraseObject: return "Paint over something to remove it"
        case .pen: return "Draw freehand"
        case .highlighter: return "Mark something see-through"
        case .text: return "Click to type a note"
        case .arrow: return "Drag to point at something"
        case .shape: return "Drag to draw a box"
        case .redact: return "Pixelate passwords, faces and numbers"
        case .pipette: return "Click the picture to take its colour"
        case .zoom: return "Look closer"
        case .enhance: return "One tap, light and colour fixed"
        case .adjust: return "Light, colour, warmth, sharpness, looks"
        case .rotate: return "Turn a quarter to the left"
        case .flip: return "Mirror left to right"
        case .convert: return "JPEG, PNG, HEIC, TIFF, PDF"
        case .resize: return "Make it smaller in pixels"
        case .compress: return "Make the file smaller"
        case .stripLocation: return "Drop where and how it was taken"
        case .copyText: return "Live Text, on this Mac"
        case .translate: return "Translate the text in it"
        case .zip: return "Make a .zip next to it"
        case .share: return "AirDrop, Mail, Messages…"
        case .rename: return "Give it a better name"
        case .copyPath: return "Copy where it lives"
        default: return title
        }
    }
}

struct ToolGroup: Identifiable {
    let title: String
    let tools: [ToolID]
    var id: String { title }
}

// MARK: - Workspace contract

/// One per open file. The shell draws the header, sidebar and bar; the workspace owns the
/// picture/PDF/video, what each tool does, and saving.
@MainActor
protocol EditWorkspace: AnyObject {
    var item: FileItem { get }
    var kind: EditKind { get }
    /// The usual four, in order.
    var bar: [ToolID] { get }
    /// Every tool, the bar's four included.
    var groups: [ToolGroup] { get }
    var active: ToolID? { get }
    /// Something changed that a save would keep.
    var hasEdits: Bool { get }
    /// Header subtitle while editing (what changed and where it will go).
    var status: String? { get }
    /// A long-running step in progress, e.g. "Finding the subject…".
    var busy: String? { get }
    var canUndo: Bool { get }

    func barTitle(_ tool: ToolID) -> String
    func isAvailable(_ tool: ToolID) -> Bool
    /// From the bar or the sidebar. Modes become active; one-shot actions just run.
    func select(_ tool: ToolID)
    func stage() -> AnyView
    /// What sits in the sidebar's options box for the active tool (or about the file).
    func options() -> AnyView
    /// Optional strip at the bottom of the sidebar (the colour palette for pictures).
    func footer() -> AnyView?
    func undo()
    func discard()
    /// Writes the copy and returns where it went.
    func save() async throws -> URL
}

extension EditWorkspace {
    func barTitle(_ tool: ToolID) -> String { tool.title }
    func isAvailable(_ tool: ToolID) -> Bool { true }
    func footer() -> AnyView? { nil }
}

enum EditError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

@MainActor
enum EditWorkspaces {
    /// Other kinds register here so the shell needn't know about them.
    static var makers: [EditKind: (FileItem) -> EditWorkspace] = [:]

    static func make(for item: FileItem) -> EditWorkspace {
        let kind = EditKind.of(item)
        if let maker = makers[kind] { return maker(item) }
        switch kind {
        case .photo, .screenshot: return PictureWorkspace(item: item, kind: kind)
        case .pdf: return PDFWorkspaceFactory.make(item)
        case .video, .audio: return MediaWorkspaceFactory.make(item, kind: kind)
        case .other: return FileWorkspace(item: item)
        }
    }
}

// MARK: - Saving copies

@MainActor
enum CopySaver {
    /// "IMG_4471 (no background).png" next to the original, never over an existing file.
    static func destination(for original: URL, suffix: String?, ext: String) -> URL {
        let dir = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        let sameExt = original.pathExtension.lowercased() == ext.lowercased()
        let stem: String
        if let suffix, !suffix.isEmpty { stem = "\(base) (\(suffix))" }
        else if sameExt { stem = "\(base) (copy)" }
        else { stem = base }
        var url = dir.appendingPathComponent(stem).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// Writable folder for the copy: next to the original, or Downloads if that folder is read-only.
    static func folder(near original: URL) -> URL {
        let dir = original.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func destination(near original: URL, suffix: String?, ext: String) -> URL {
        let probe = folder(near: original).appendingPathComponent(original.lastPathComponent)
        return destination(for: probe, suffix: suffix, ext: ext)
    }

    /// Makes the new file show up straight away, before the folder watcher notices it.
    @discardableResult
    static func register(_ url: URL, like original: FileItem) -> FileItem? {
        guard let item = FileScanner.makeItem(url: url, rootName: original.rootName) else { return nil }
        FileIndex.shared.upsert([item])
        return item
    }

    /// Undo a save: the copy goes to the Trash.
    static func undo(_ url: URL) {
        var trashed: NSURL?
        guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil else { return }
        FileIndex.shared.remove(paths: [url.path])
        if let t = trashed as URL? {
            RemovalLog.shared.recordTrashed([(url, t, RemovalLog.fileSize(t))], automatic: false, reason: "Edited copy", from: "Preview")
        }
    }

    /// Replace the original with the copy: the original goes to the Trash (so it can come back),
    /// the copy takes the original's name (keeping its own extension if the format changed).
    static func replaceOriginal(_ original: FileItem, with copy: URL) throws -> URL {
        let target = original.url.deletingPathExtension().appendingPathExtension(copy.pathExtension)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: original.url, resultingItemURL: &trashed)
        FileIndex.shared.remove(paths: [original.path])
        if let t = trashed as URL? {
            RemovalLog.shared.recordReplaced(original: original.url, trashed: t, size: original.size, copyName: target.lastPathComponent)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            // Another file already had the copy's new name (same name, other format): it goes to the Trash too.
            var other: NSURL?
            let size = RemovalLog.fileSize(target)
            try FileManager.default.trashItem(at: target, resultingItemURL: &other)
            if let o = other as URL? { RemovalLog.shared.recordReplaced(original: target, trashed: o, size: size, copyName: target.lastPathComponent) }
        }
        try FileManager.default.moveItem(at: copy, to: target)
        FileIndex.shared.remove(paths: [copy.path])
        register(target, like: original)
        return target
    }
}

// MARK: - Messages shown over the preview (they outlive the sheet when it switches files)

@MainActor
@Observable
final class EditToastCenter {
    static let shared = EditToastCenter()

    struct Saved: Equatable {
        let original: FileItem
        let copy: URL
        static func == (a: Saved, b: Saved) -> Bool { a.copy == b.copy }

        /// Replacing only makes sense for one file of the same kind (a PNG for a HEIC, an MP4 for a MOV),
        /// not for a folder of pages, a transcript or a GIF made from a video.
        var canReplace: Bool {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: copy.path, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.fileExists(atPath: original.path) else { return false }
            let ext = copy.pathExtension.lowercased()
            return FileCategory.classify(ext: ext, type: UTType(filenameExtension: ext)) == original.category
        }
    }

    var saved: Saved?
    var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func show(saved: Saved) {
        self.saved = saved; message = nil
        schedule(10)
    }

    func show(_ text: String) {
        message = text; saved = nil
        schedule(4)
    }

    func clear() { saved = nil; message = nil; task?.cancel() }

    private func schedule(_ seconds: Double) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self.saved = nil; self.message = nil }
        }
    }
}
