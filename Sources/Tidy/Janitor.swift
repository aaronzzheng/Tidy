import AppKit

/// Watches a couple of folders and applies small, reversible rules to them.
///
/// Every rule either renames in place or moves a file — to a sibling folder or to
/// the Trash. Nothing is ever deleted outright, so a rule that misfires is undone
/// by dragging the file back.
final class Janitor: ObservableObject {

    struct Action: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let text: String
    }

    /// Extension buckets. Anything not listed is deliberately left alone rather
    /// than swept into a catch-all folder.
    static let categories: [(folder: String, extensions: Set<String>)] = [
        ("Images", ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"]),
        ("Documents", ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt",
                       "md", "csv", "rtf", "pages", "numbers", "key", "epub"]),
        ("Archives", ["zip", "tar", "gz", "tgz", "bz2", "7z", "rar"]),
        ("Installers", ["dmg", "pkg"]),
        ("Media", ["mp4", "mov", "mp3", "m4a", "wav", "avi", "mkv", "aiff"]),
    ]

    /// Partial downloads. Touching one mid-flight corrupts it.
    private static let inProgressExtensions: Set<String> =
        ["download", "crdownload", "part", "partial", "opdownload", "tmp"]

    /// A file still being written has a moving size; leave it a moment.
    private static let settleSeconds: TimeInterval = 60

    @Published var renameScreenshots = true { didSet { persist() } }
    @Published var sortDownloads = false { didSet { persist() } }
    @Published var trashOldInstallers = false { didSet { persist() } }
    @Published var installerAgeDays = 7 { didSet { persist() } }
    @Published private(set) var log: [Action] = []

    /// Overridable so the rules can be exercised against a scratch folder rather
    /// than the real ones.
    var downloadsFolder: URL = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var screenshotsFolder: URL = Janitor.screenshotFolder()

    private var watchers: [DirectoryWatcher] = []
    private var pending: DispatchWorkItem?
    private let defaults = UserDefaults.standard

    // MARK: Lifecycle

    init() {
        if defaults.object(forKey: "Tidy.renameScreenshots") != nil {
            renameScreenshots = defaults.bool(forKey: "Tidy.renameScreenshots")
            sortDownloads = defaults.bool(forKey: "Tidy.sortDownloads")
            trashOldInstallers = defaults.bool(forKey: "Tidy.trashOldInstallers")
            installerAgeDays = defaults.integer(forKey: "Tidy.installerAgeDays")
        }
        log = (defaults.array(forKey: "Tidy.log") as? [String] ?? []).map {
            Action(date: Date(), text: $0)
        }
    }

    private func persist() {
        defaults.set(renameScreenshots, forKey: "Tidy.renameScreenshots")
        defaults.set(sortDownloads, forKey: "Tidy.sortDownloads")
        defaults.set(trashOldInstallers, forKey: "Tidy.trashOldInstallers")
        defaults.set(installerAgeDays, forKey: "Tidy.installerAgeDays")
    }

    func start() {
        var folders = [downloadsFolder]
        if screenshotsFolder != downloadsFolder { folders.append(screenshotsFolder) }

        watchers = folders.compactMap { folder in
            DirectoryWatcher(folder) { [weak self] in self?.scheduleSweep() }
        }
        sweep()
    }

    func stop() {
        watchers.forEach { $0.stop() }
        watchers.removeAll()
    }

    /// A single download produces a burst of directory events; run once after.
    private func scheduleSweep() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sweep() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Rules

    func sweep() {
        if renameScreenshots { renameScreenshotsNow() }
        if sortDownloads { sortDownloadsNow() }
        if trashOldInstallers { trashOldInstallersNow() }
    }

    func renameScreenshotsNow() {
        let folder = screenshotsFolder
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName
        for url in contents(of: folder) where Self.looksLikeScreenshot(url) {
            guard hasSettled(url) else { continue }
            guard let app = frontmost, app != "Tidy" else { continue }

            let stamp = Self.stampFormatter.string(from: Self.creationDate(url) ?? Date())
            let base = "\(Self.sanitize(app)) — \(stamp)"
            let destination = Self.uniqueURL(in: folder, base: base,
                                             extension: url.pathExtension)
            move(url, to: destination, verb: "Renamed")
        }
    }

    func sortDownloadsNow() {
        let folderNames = Set(Self.categories.map(\.folder))
        for url in contents(of: downloadsFolder) {
            guard !isDirectory(url), hasSettled(url) else { continue }
            let ext = url.pathExtension.lowercased()
            guard !Self.inProgressExtensions.contains(ext) else { continue }
            guard let category = Self.categories.first(where: { $0.extensions.contains(ext) })
            else { continue }   // unknown kinds are left where they are, on purpose
            guard !folderNames.contains(url.deletingLastPathComponent().lastPathComponent)
            else { continue }

            let target = downloadsFolder.appendingPathComponent(category.folder,
                                                               isDirectory: true)
            try? FileManager.default.createDirectory(at: target,
                                                     withIntermediateDirectories: true)
            let destination = Self.uniqueURL(in: target,
                                             base: url.deletingPathExtension().lastPathComponent,
                                             extension: url.pathExtension)
            move(url, to: destination, verb: "Filed into \(category.folder):")
        }
    }

    func trashOldInstallersNow() {
        let cutoff = Date().addingTimeInterval(-Double(installerAgeDays) * 86_400)
        let installers = downloadsFolder.appendingPathComponent("Installers", isDirectory: true)
        for folder in [downloadsFolder, installers] {
            for url in contents(of: folder) {
                guard ["dmg", "pkg"].contains(url.pathExtension.lowercased()) else { continue }
                guard let modified = Self.modifiedDate(url), modified < cutoff else { continue }
                var trashed: NSURL?
                // Trash, never delete: a wrong guess costs a drag back out.
                try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                if !FileManager.default.fileExists(atPath: url.path) {
                    record("Trashed \(url.lastPathComponent) — older than \(installerAgeDays) days")
                }
            }
        }
    }

    // MARK: Mechanics

    private func move(_ url: URL, to destination: URL, verb: String) {
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            record("\(verb) \(url.lastPathComponent) → \(destination.lastPathComponent)")
        } catch {
            record("Couldn't move \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private func hasSettled(_ url: URL) -> Bool {
        guard let modified = Self.modifiedDate(url) else { return false }
        return Date().timeIntervalSince(modified) > Self.settleSeconds
    }

    private func record(_ text: String) {
        log.insert(Action(date: Date(), text: text), at: 0)
        if log.count > 20 { log.removeLast(log.count - 20) }
        defaults.set(log.map(\.text), forKey: "Tidy.log")
    }

    func clearLog() {
        log = []
        defaults.removeObject(forKey: "Tidy.log")
    }

    // MARK: Helpers

    /// Where macOS is currently saving screenshots. Unset means the Desktop.
    static func screenshotFolder() -> URL {
        let location = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location")
        guard let location, !location.isEmpty else {
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        return URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
    }

    /// `kMDItemIsScreenCapture` is not reliably set, so go by the name macOS
    /// gives them. Covers both the current and the older wording.
    static func looksLikeScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return false }
        return name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ")
    }

    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    static func uniqueURL(in folder: URL, base: String, extension ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    static func modifiedDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func creationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

/// Fires whenever a directory's contents change.
final class DirectoryWatcher {
    private let descriptor: CInt
    private let source: DispatchSourceFileSystemObject

    init?(_ url: URL, onChange: @escaping () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    func stop() { source.cancel() }
    deinit { source.cancel() }
}
