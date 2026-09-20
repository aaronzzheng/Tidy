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
    /// A screenshot is written once, whole. It only needs long enough for the
    /// write to have finished, not the minute a download gets.
    private static let screenshotSettleSeconds: TimeInterval = 3

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

    /// Screenshots that appeared while Tidy was running, with the app that was in
    /// front at that moment. The rename rule works from this and nothing else:
    /// a screenshot that was already on disk when Tidy started has no owner we
    /// can know, and naming it after whatever happens to be in front now would
    /// be wrong more often than right.
    private var screenshotOwners: [URL: String] = [:]
    /// Everything in the screenshots folder that looked like a screenshot the
    /// last time we looked, so a folder event can tell new arrivals from old.
    private var seenScreenshots: Set<URL> = []

    private var watchers: [DirectoryWatcher] = []
    private var pending: DispatchWorkItem?
    private let defaults = UserDefaults.standard

    // MARK: Lifecycle

    init() {
        if defaults.object(forKey: "Tidy.renameScreenshots") != nil {
            renameScreenshots = defaults.bool(forKey: "Tidy.renameScreenshots")
            sortDownloads = defaults.bool(forKey: "Tidy.sortDownloads")
            trashOldInstallers = defaults.bool(forKey: "Tidy.trashOldInstallers")
            // A zero here would make "older than" mean "all of them".
            installerAgeDays = max(1, defaults.integer(forKey: "Tidy.installerAgeDays"))
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
        seenScreenshots = Set(contents(of: screenshotsFolder).filter(Self.looksLikeScreenshot))

        let watchesScreenshots = screenshotsFolder == downloadsFolder
        if let downloads = DirectoryWatcher(downloadsFolder, onChange: { [weak self] in
            if watchesScreenshots { self?.noteNewScreenshots() }
            self?.scheduleSweep()
        }) {
            watchers.append(downloads)
        }
        if !watchesScreenshots,
           let screenshots = DirectoryWatcher(screenshotsFolder, onChange: { [weak self] in
               // Read the frontmost app *now*, while the screenshot is fresh, not
               // when the file has settled and you have long since moved on.
               self?.noteNewScreenshots()
               self?.scheduleSweep()
           }) {
            watchers.append(screenshots)
        }
        sweep()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        watchers.forEach { $0.stop() }
        watchers.removeAll()
    }

    /// A single download produces a burst of directory events; run once after.
    private func scheduleSweep(after delay: TimeInterval = 1.5) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sweep() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Records who was in front for any screenshot that has just appeared.
    private func noteNewScreenshots() {
        let current = Set(contents(of: screenshotsFolder).filter(Self.looksLikeScreenshot))
        let arrived = current.subtracting(seenScreenshots)
        seenScreenshots = current
        guard !arrived.isEmpty else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName
        guard let frontmost, frontmost != "Tidy" else { return }
        for url in arrived { screenshotOwners[url] = frontmost }
    }

    // MARK: Rules

    /// Runs every enabled rule. Files too fresh to touch are left for a follow-up
    /// sweep scheduled for the moment the earliest of them settles — without
    /// that, a rule would only ever fire on the *next* thing to land in the
    /// folder, a minute or more after the file it was meant for.
    func sweep() {
        var nextDue: Date?
        func note(_ due: Date?) {
            guard let due else { return }
            nextDue = nextDue.map { min($0, due) } ?? due
        }
        if renameScreenshots { note(renameScreenshotsNow()) }
        if sortDownloads { note(sortDownloadsNow()) }
        if trashOldInstallers { trashOldInstallersNow() }

        if let nextDue {
            scheduleSweep(after: max(0.5, nextDue.timeIntervalSinceNow + 0.5))
        }
    }

    /// Returns when the earliest not-yet-settled screenshot will be ready, if any.
    @discardableResult
    func renameScreenshotsNow() -> Date? {
        var earliest: Date?
        for (url, app) in screenshotOwners {
            guard FileManager.default.fileExists(atPath: url.path) else {
                screenshotOwners[url] = nil
                continue
            }
            if let due = settleDate(url, after: Self.screenshotSettleSeconds) {
                earliest = earliest.map { min($0, due) } ?? due
                continue
            }

            let stamp = Self.stampFormatter.string(from: Self.creationDate(url) ?? Date())
            let base = "\(Self.sanitize(app)) — \(stamp)"
            let destination = Self.uniqueURL(in: url.deletingLastPathComponent(), base: base,
                                             extension: url.pathExtension)
            move(url, to: destination, verb: "Renamed")
            screenshotOwners[url] = nil
            seenScreenshots.remove(url)
        }
        return earliest
    }

    /// Returns when the earliest not-yet-settled download will be ready, if any.
    @discardableResult
    func sortDownloadsNow() -> Date? {
        var earliest: Date?
        for url in contents(of: downloadsFolder) {
            guard !isDirectory(url) else { continue }
            let ext = url.pathExtension.lowercased()
            guard !Self.inProgressExtensions.contains(ext) else { continue }
            guard let category = Self.categories.first(where: { $0.extensions.contains(ext) })
            else { continue }   // unknown kinds are left where they are, on purpose
            if let due = settleDate(url, after: Self.settleSeconds) {
                earliest = earliest.map { min($0, due) } ?? due
                continue
            }

            let target = downloadsFolder.appendingPathComponent(category.folder,
                                                               isDirectory: true)
            try? FileManager.default.createDirectory(at: target,
                                                     withIntermediateDirectories: true)
            let destination = Self.uniqueURL(in: target,
                                             base: url.deletingPathExtension().lastPathComponent,
                                             extension: url.pathExtension)
            move(url, to: destination, verb: "Filed into \(category.folder):")
        }
        return earliest
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

    /// Nil once the file has been left alone long enough to touch; otherwise the
    /// moment it will have been. A file whose dates cannot be read is never
    /// settled — better to skip it than to move something half-written.
    private func settleDate(_ url: URL, after settle: TimeInterval) -> Date? {
        guard let modified = Self.modifiedDate(url) else { return .distantFuture }
        let due = modified.addingTimeInterval(settle)
        return due <= Date() ? nil : due
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
            .standardizedFileURL
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
