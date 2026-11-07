import Foundation
import UniformTypeIdentifiers

enum FileCategory: String, CaseIterable, Codable, Identifiable, Hashable {
    case images, videos, music, documents, archives, apps, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return "Images"
        case .videos: return "Videos"
        case .music: return "Music"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .apps: return "Apps"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .images: return "photo.on.rectangle.angled"
        case .videos: return "film.stack"
        case .music: return "music.note"
        case .documents: return "doc.richtext"
        case .archives: return "archivebox"
        case .apps: return "square.grid.2x2"
        case .other: return "doc"
        }
    }

    static let library: [FileCategory] = [.images, .videos, .music, .documents, .archives, .apps]

    static let archiveExts: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "lz", "lzma",
        "sit", "sitx", "cab", "jar", "dmg", "pkg", "mpkg", "iso", "cpio", "xip"
    ]
    static let documentExts: Set<String> = [
        "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx",
        "odt", "ods", "odp", "rtf", "rtfd", "txt", "md", "markdown", "csv", "tsv", "epub", "mobi"
    ]
    static let installerExts: Set<String> = ["dmg", "pkg", "mpkg"]

    static func classify(ext: String, type: UTType?) -> FileCategory {
        if ext == "app" { return .apps }
        if archiveExts.contains(ext) { return .archives }
        if documentExts.contains(ext) { return .documents }
        guard let t = type else { return .other }
        if t.conforms(to: .applicationBundle) || t.conforms(to: .application) { return .apps }
        if t.conforms(to: .image) { return .images }
        if t.conforms(to: .audio) { return .music }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .videos }
        if t.conforms(to: .archive) || t.conforms(to: .diskImage) { return .archives }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) || t.conforms(to: .propertyList)
            || t.conforms(to: .json) || t.conforms(to: .xml) || t.conforms(to: .html) {
            return .other
        }
        if t.conforms(to: .pdf) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet)
            || t.conforms(to: .rtf) || t.conforms(to: .epub) || t.conforms(to: .plainText) {
            return .documents
        }
        return .other
    }
}

struct FileItem: Identifiable, Hashable {
    let path: String
    let url: URL
    var name: String
    var ext: String
    var category: FileCategory
    var typeIdentifier: String?
    var size: Int64 = 0
    var created: Date?
    var modified: Date?
    var added: Date?
    var tags: [String] = []
    var whereFroms: [String] = []
    var source: DownloadSource?
    var isScreenshot = false
    var isCloudOnly = false
    var isFolder = false
    var isPackage = false
    var rootName: String = ""

    // Filled in by the background enricher (cached in SQLite).
    var camera: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    var hasText = false

    var id: String { path }

    /// The date that best answers "when did I last deal with this file".
    var activityDate: Date {
        let m = modified ?? .distantPast
        let a = added ?? .distantPast
        let best = max(m, a)
        return best == .distantPast ? (created ?? .distantPast) : best
    }

    var sortDate: Date { activityDate }
    var baseName: String { (name as NSString).deletingPathExtension }
    var parentPath: String { (path as NSString).deletingLastPathComponent }
    var parentName: String { (parentPath as NSString).lastPathComponent }
    var sourceName: String { source?.name ?? "" }
    var isInstaller: Bool { FileCategory.installerExts.contains(ext) }
    var modifiedStamp: Double { modified?.timeIntervalSince1970 ?? 0 }

    var kindName: String {
        if isFolder { return "Folder" }
        if let id = typeIdentifier, let t = UTType(id), let d = t.localizedDescription { return d }
        return ext.isEmpty ? "Document" : ext.uppercased()
    }

    var dimensionsText: String? {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return nil }
        return "\(w) × \(h)"
    }

    var shortPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Wrapper that lets SwiftUI drag one or many files into other apps.
import CoreTransferable
struct DragFile: Transferable, Identifiable {
    let id: String
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.url)
    }
}
