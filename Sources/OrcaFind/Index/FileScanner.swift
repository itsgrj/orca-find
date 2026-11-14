import Foundation
import UniformTypeIdentifiers

enum XAttr {
    static func data(_ path: String, _ name: String) -> Data? {
        let len = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return nil }
        var data = Data(count: len)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, len, 0, XATTR_NOFOLLOW) }
        return read > 0 ? data : nil
    }

    static func has(_ path: String, _ name: String) -> Bool {
        getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    static func whereFroms(_ path: String) -> [String] {
        guard let d = data(path, "com.apple.metadata:kMDItemWhereFroms"),
              let list = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String] else { return [] }
        return list.filter { !$0.isEmpty }
    }

    static func isScreenCapture(_ path: String) -> Bool {
        has(path, "com.apple.metadata:kMDItemIsScreenCapture")
    }
}

enum FileScanner {
    struct Root: Hashable {
        let url: URL
        let name: String
        let maxDepth: Int
        /// Found by search, never offered for tidying: the person's own folders in their home folder.
        var searchOnly = false
        /// Watched for live changes. Off for the home folder itself (its hidden Library changes all the time).
        var watched = true

        /// The file or folder at `path` belongs to this root (see FileScanner.root(for:in:) when roots nest).
        func covers(_ path: String) -> Bool {
            maxDepth <= 1 ? (path as NSString).deletingLastPathComponent == url.path : path.hasPrefix(url.path + "/")
        }
    }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey,
        .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey, .contentTypeKey,
        .tagNamesKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]
    static let keySet = Set(resourceKeys)

    static let skippedDirectories: Set<String> = [
        "node_modules", "Pods", "DerivedData", "__pycache__", "site-packages", ".build", "venv",
        "bower_components", "Caches", "vendor/bundle", ".Trash", "Carthage"
    ]
    static let keptPackageExts: Set<String> = ["app", "pages", "key", "numbers", "rtfd", "pkg", "mpkg"]

    static let screenshotPrefixes = ["Screenshot ", "Screen Shot ", "CleanShot ", "Capture d’écran", "Bildschirmfoto", "Captura de pantalla", "スクリーンショット"]

    static func defaultFolderNames() -> [String] { ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"] }

    /// The most specific root holding `path` (an added folder can sit inside a home folder).
    static func root(for path: String, in roots: [Root]) -> Root? {
        roots.filter { $0.covers(path) }.max { $0.url.path.count < $1.url.path.count }
    }

    /// Settings switch (in disabledDefaultFolders) for "everything else in your home folder".
    static let homeSettingName = "Home"

    /// Never searched in the home folder: where macOS and apps keep their own data, the Applications
    /// folder (a root of its own), and tool kits developers install there (tens of thousands of files each).
    static let skippedHomeFolders: Set<String> = [
        "Library", "Applications", "anaconda3", "miniconda3", "miniforge3", "mambaforge", "opt", "go", "flutter",
        "OrbStack", "VirtualBox VMs", "Parallels"
    ]

    /// Loose files in the home folder itself, plus one root per folder kept there next to Desktop and
    /// Documents ("SigmaFlow", "Claude"…). None of these need a permission prompt.
    static func homeRoots(home: URL, skipping taken: Set<String>) -> [Root] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isVolumeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out = [Root(url: home, name: homeSettingName, maxDepth: 1, searchOnly: true, watched: false)]
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard !taken.contains(name), !skippedHomeFolders.contains(name), !skippedDirectories.contains(name),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isDirectory == true, v.isPackage != true, v.isSymbolicLink != true,
                  v.isVolume != true   // a mounted drive or cloud disk shown in the home folder
            else { continue }
            out.append(Root(url: url, name: name, maxDepth: 14, searchOnly: true))
        }
        return out
    }

    static func roots(extraFolders: [String], disabledDefaults: Set<String>) -> [Root] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var roots: [Root] = defaultFolderNames()
            .filter { !disabledDefaults.contains($0) }
            .map { Root(url: home.appendingPathComponent($0), name: $0, maxDepth: 14) }
        roots.append(Root(url: URL(fileURLWithPath: "/Applications"), name: "Applications", maxDepth: 2))
        let userApps = home.appendingPathComponent("Applications")
        if FileManager.default.fileExists(atPath: userApps.path) {
            roots.append(Root(url: userApps, name: "Applications", maxDepth: 2))
        }
        for path in extraFolders {
            let url = URL(fileURLWithPath: path)
            if !roots.contains(where: { path.hasPrefix($0.url.path + "/") || $0.url.path == path }) {
                roots.append(Root(url: url, name: url.lastPathComponent, maxDepth: 14))
            }
        }
        // After the added folders, so a folder someone added by hand keeps its clean-up suggestions.
        if !disabledDefaults.contains(homeSettingName) {
            let earlier = roots   // not the home roots themselves: every own folder sits "inside" the home root
            for r in homeRoots(home: home, skipping: Set(defaultFolderNames()))
            where !earlier.contains(where: { r.url.path == $0.url.path || r.url.path.hasPrefix($0.url.path + "/") }) {
                roots.append(r)
            }
        }
        return roots
    }

    /// Packages owned by other apps (and guarded by macOS privacy): never open or read their attributes.
    static let protectedPackageExts: Set<String> = [
        "photoslibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "photobooth", "logicx", "band", "xcodeproj", "xcworkspace", "bundle", "framework", "plugin"
    ]

    /// Cheap keys only (plain stat); tags and xattrs are read later, for files we keep.
    static let walkKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey]

    private final class ScanBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: FileItem] = [:]
        func add(_ batch: [FileItem]) -> Int {
            lock.lock(); defer { lock.unlock() }
            for i in batch { items[i.path] = i }
            return items.count
        }
        func snapshot() -> [FileItem] {
            lock.lock(); defer { lock.unlock() }
            return Array(items.values)
        }
    }

    /// Walks every root concurrently and returns one item per file. If a folder stalls (for example
    /// a cloud provider that never answers), whatever was found is returned after `timeout`.
    static func scan(roots: [Root], timeout: TimeInterval = 120, progress: ((Int) -> Void)? = nil) -> [FileItem] {
        let box = ScanBox()
        let group = DispatchGroup()
        for root in roots {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                scanRoot(root, into: box, progress: progress)
                group.leave()
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("OrcaFind: a folder took longer than \(Int(timeout))s to scan; continuing with what was found.")
        }
        return box.snapshot()
    }

    private static func scanRoot(_ root: Root, into box: ScanBox, progress: ((Int) -> Void)?) {
        guard let en = FileManager.default.enumerator(
            at: root.url, includingPropertiesForKeys: walkKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { return }
        var local: [FileItem] = []
        let walkSet = Set(walkKeys)
        for case let url as URL in en {
            if en.level > root.maxDepth { en.skipDescendants(); continue }
            guard let basic = try? url.resourceValues(forKeys: walkSet) else { continue }
            if basic.isHidden == true || basic.isSymbolicLink == true {
                if basic.isDirectory == true { en.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            if basic.isDirectory == true {
                if basic.isPackage == true {
                    if protectedPackageExts.contains(ext) || !keptPackageExts.contains(ext) { continue }
                } else {
                    // Never open a folder whose contents would be past the depth limit (the home folder's
                    // own root lists only its loose files, so Desktop, Library… are never opened here).
                    if skippedDirectories.contains(basic.name ?? url.lastPathComponent) || en.level >= root.maxDepth { en.skipDescendants() }
                    continue
                }
            }
            if let item = makeItem(url: url, rootName: root.name) {
                local.append(item)
            }
            if local.count >= 1500 {
                let n = box.add(local)
                local.removeAll(keepingCapacity: true)
                progress?(n)
            }
        }
        let n = box.add(local)
        progress?(n)
    }

    static func makeItem(url: URL, rootName: String, values: URLResourceValues? = nil) -> FileItem? {
        if protectedPackageExts.contains(url.pathExtension.lowercased())
            || url.pathComponents.contains(where: { protectedPackageExts.contains(($0 as NSString).pathExtension.lowercased()) }) {
            return nil
        }
        guard let v = values ?? (try? url.resourceValues(forKeys: keySet)) else { return nil }
        if v.isHidden == true || v.isSymbolicLink == true { return nil }
        let isDir = v.isDirectory ?? false
        let isPkg = v.isPackage ?? false
        let ext = url.pathExtension.lowercased()
        if isDir && !isPkg { return nil }
        if isPkg && !keptPackageExts.contains(ext) { return nil }

        let path = url.path
        let name = v.name ?? url.lastPathComponent
        let type = v.contentType ?? UTType(filenameExtension: ext)
        var item = FileItem(path: path, url: url, name: name, ext: ext,
                            category: FileCategory.classify(ext: ext, type: type))
        item.typeIdentifier = type?.identifier
        item.size = Int64(v.fileSize ?? 0)
        item.created = v.creationDate
        item.modified = v.contentModificationDate
        item.added = v.addedToDirectoryDate
        item.tags = v.tagNames ?? []
        item.isPackage = isPkg
        item.rootName = rootName
        item.whereFroms = XAttr.whereFroms(path)
        item.source = DownloadSource.detect(item.whereFroms)
        if item.category == .images {
            item.isScreenshot = XAttr.isScreenCapture(path) || screenshotPrefixes.contains { name.hasPrefix($0) }
        }
        if v.isUbiquitousItem == true, let status = v.ubiquitousItemDownloadingStatus, status == .notDownloaded {
            item.isCloudOnly = true
        }
        return item
    }

    /// Lists one folder (non-recursive), including subfolders, for the pinned-folder browser.
    static func list(folder: URL, rootName: String) -> [FileItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: walkKeys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [FileItem] = []
        for url in urls {
            if protectedPackageExts.contains(url.pathExtension.lowercased()) { continue }
            guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
            if v.isDirectory == true && v.isPackage != true {
                var f = FileItem(path: url.path, url: url, name: v.name ?? url.lastPathComponent, ext: "", category: .other)
                f.isFolder = true
                f.created = v.creationDate
                f.modified = v.contentModificationDate
                f.added = v.addedToDirectoryDate
                f.tags = v.tagNames ?? []
                f.rootName = rootName
                out.append(f)
            } else if let item = makeItem(url: url, rootName: rootName, values: v) {
                out.append(item)
            }
        }
        return out
    }
}
