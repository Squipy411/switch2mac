import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

var project: URL {
    if let override = ProcessInfo.processInfo.environment["SWITCH2MAC_PROJECT"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
    if let configured = UserDefaults.standard.string(forKey: "builder.switch2mac"), !configured.isEmpty {
        return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
    }
    let fm = FileManager.default
    if let resource = Bundle.main.resourceURL?.appendingPathComponent("Engine"),
       fm.isReadableFile(atPath: resource.appendingPathComponent("switch2mac.py").path) {
        return resource
    }
    var ancestor = Bundle.main.bundleURL.deletingLastPathComponent()
    while ancestor.path != "/" {
        if fm.isReadableFile(atPath: ancestor.appendingPathComponent("switch2mac.py").path) { return ancestor }
        ancestor.deleteLastPathComponent()
    }
    return fm.homeDirectoryForCurrentUser.appendingPathComponent("Projects/Development/switch2mac", isDirectory: true)
}

private var automaticPaths: [URL] {
    [URL(fileURLWithPath: "/Applications/Mario Kart World M2.app"),
     project.appendingPathComponent("work/Portable Game/Mario Kart World.app"),
     URL(fileURLWithPath: "/Applications/Mario Kart World.app"),
     project.appendingPathComponent("work/Mario Kart World.app")]
}

struct LibraryRecord: Codable {
    let id: String
    var path: String
    var bookmark: Data?
    var title: String
    var bundleID: String?
    var titleID: String?
    var version: String?
    var volumeID: String?
    var volumeName: String?

    init(url: URL, id: String? = nil) {
        self.id = id ?? url.path
        self.path = url.path
        let app = GameBundle(url)
        self.title = app?.name ?? url.deletingPathExtension().lastPathComponent
        self.bundleID = app?.bundleID
        self.titleID = app?.titleID
        self.version = app?.version
        self.bookmark = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        let volume = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey, .volumeIsInternalKey])
        if volume?.volumeIsInternal == false || url.path.hasPrefix("/Volumes/") {
            self.volumeID = volume?.volumeUUIDString
            self.volumeName = volume?.volumeName ?? url.pathComponents.dropFirst(2).first
        }
    }
}

struct GameBundle {
    let url: URL
    let info: [String: Any]
    let executable: URL
    let manifest: [String: Any]

    init?(_ url: URL) {
        guard url.pathExtension.lowercased() == "app",
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let filename = info["CFBundleExecutable"] as? String, !filename.isEmpty,
              !filename.contains("/"), filename != ".", filename != ".." else { return nil }
        self.url = url
        self.info = info
        self.executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(filename)
        if info["Switch2MacPortable"] as? Bool == true,
           let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Resources/portable.json")),
           let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            self.manifest = metadata
        } else {
            self.manifest = [:]
        }
    }

    var name: String { info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent }
    var bundleID: String? { info["CFBundleIdentifier"] as? String }
    var version: String? { info["CFBundleShortVersionString"] as? String }
    var titleID: String? {
        guard let id = (info["DMTitleID"] as? String)?.uppercased(),
              id.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil else { return nil }
        return id
    }
    var resources: URL { url.appendingPathComponent("Contents/Resources", isDirectory: true) }
    var isPortable: Bool { info["Switch2MacPortable"] as? Bool == true }
    var performanceProfile: [String: Any]? { manifest["performanceProfile"] as? [String: Any] }
    var hasPackagedPerformance: Bool { performanceProfile != nil }
    var supportsPreferredController: Bool {
        (manifest["capabilities"] as? [String: Any])?["preferredPlayerOneController"] as? Bool == true
    }

    var issue: String? {
        let fm = FileManager.default
        func readableFile(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && fm.isReadableFile(atPath: url.path)
        }
        guard readableFile(executable), fm.isExecutableFile(atPath: executable.path) else {
            return "The application is missing its executable."
        }
        if isPortable || (titleID != nil && executable.lastPathComponent == "nxnative") {
            let runtime = url.appendingPathComponent("Contents/MacOS/dmhost")
            guard readableFile(runtime), fm.isExecutableFile(atPath: runtime.path) else {
                return "The native runtime is missing from the application."
            }
            let modules = resources.appendingPathComponent("dm/main.patched.bin")
            guard readableFile(modules) else { return "The application is missing its game modules." }
            if isPortable {
                guard let titleID, manifest["schemaVersion"] as? Int == 1, manifest["titleID"] as? String == titleID else {
                    return "The application’s portable manifest is missing or invalid."
                }
                let image = resources.appendingPathComponent("romfs.img")
                guard readableFile(image) else { return "The application is missing its RomFS image." }
                if hasPackagedPerformance, !readableFile(resources.appendingPathComponent("dm-performance/main.patched.bin")) {
                    return "The application is missing its bundled performance modules."
                }
                if let chain = info["DMChain"] as? String {
                    guard chain.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil else {
                        return "The application declares an invalid Metal shader chain."
                    }
                    let image = resources.appendingPathComponent("msl/b-\(chain).img")
                    if !readableFile(image) {
                        let folder = resources.appendingPathComponent("msl/b-\(chain)", isDirectory: true)
                        let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                        let hasLibrary = files?.contains { entry in
                            guard let file = entry as? URL, file.pathExtension == "metallib" else { return false }
                            return readableFile(file)
                        } ?? false
                        guard hasLibrary else { return "The application is missing its matching Metal shaders." }
                    }
                }
            }
        }
        return nil
    }
}

struct Game: Identifiable {
    let record: LibraryRecord
    let url: URL
    let bundle: GameBundle?
    let issue: String?
    let automatic: Bool

    var id: String { record.id }
    var title: String { bundle?.name ?? record.title }
    var version: String { bundle?.version ?? record.version ?? "—" }
    var titleID: String? { bundle?.titleID ?? record.titleID }
    var status: String {
        if issue == nil { return "Ready" }
        return FileManager.default.fileExists(atPath: url.path) ? "Needs attention" : "Offline"
    }
    var location: String { record.volumeName ?? "This Mac" }
    var saveRoot: URL? {
        guard let titleID else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nxnative", isDirectory: true)
            .appendingPathComponent(titleID, isDirectory: true)
    }
    var settingsURL: URL? { saveRoot?.appendingPathComponent("switch2mac-settings.json") }
}

@MainActor final class Library: ObservableObject {
    @Published private(set) var favorites = Set(UserDefaults.standard.stringArray(forKey: "library.favorites") ?? [])
    @Published private(set) var launches = UserDefaults.standard.dictionary(forKey: "library.launches") as? [String: Double] ?? [:]
    @Published private(set) var games: [Game] = []
    @Published private(set) var busy = Set<String>()
    @Published private(set) var artworkRevision = 0
    @Published var error: String?
    @Published var notice: String?
    private var records: [LibraryRecord] = []
    private let defaults = UserDefaults.standard
    private let fm = FileManager.default
    private let icons = NSCache<NSString, NSImage>()
    private var observers: [NSObjectProtocol] = []

    init() {
        icons.countLimit = 100
        if let data = defaults.data(forKey: "library.records"),
           let stored = try? JSONDecoder().decode([LibraryRecord].self, from: data) { records = stored }
        load()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.load() }
            })
        }
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func resolve(_ record: LibraryRecord, automatic: Bool = false) -> Game {
        let original = URL(fileURLWithPath: record.path)
        var url = original
        if !fm.fileExists(atPath: original.path), let bookmark = record.bookmark {
            var stale = false
            if let relocated = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = relocated
            }
        }
        let bundle = GameBundle(url)
        let issue: String?
        if !fm.fileExists(atPath: url.path) {
            issue = record.volumeName.map { "Connect \($0) or locate the application." } ?? "Locate the application to reconnect it."
        } else if let expected = record.volumeID,
                  (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) != expected {
            issue = "The application is on a different volume. Locate the original game or select its new copy."
        } else if let expected = record.bundleID, expected != bundle?.bundleID {
            issue = "A different application is at this location. Locate the original game."
        } else if let expected = record.titleID, expected != bundle?.titleID {
            issue = "The application has a different game title ID."
        } else if let bundle {
            issue = bundle.issue
        } else {
            issue = "The application bundle could not be read."
        }
        return Game(record: record, url: url, bundle: bundle, issue: issue, automatic: automatic)
    }

    func load() {
        icons.removeAllObjects()
        let savedPaths = Set(records.map(\.path))
        for path in defaults.stringArray(forKey: "library.apps") ?? [] where !savedPaths.contains(path) {
            if !records.contains(where: { $0.path == path }) {
                records.append(LibraryRecord(url: URL(fileURLWithPath: path)))
            }
        }
        var refreshed = records.map { resolve($0) }
        if let url = automaticPaths.first(where: { candidate in
            guard let bundle = GameBundle(candidate) else { return false }
            return bundle.issue == nil
        }),
           !refreshed.contains(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }),
           !defaults.bool(forKey: "library.hideAutomaticGame") {
            let automatic = resolve(LibraryRecord(url: url), automatic: true)
            if !refreshed.contains(where: { $0.bundle?.bundleID != nil && $0.bundle?.bundleID == automatic.bundle?.bundleID }) {
                refreshed.insert(automatic, at: 0)
            }
        }
        games = refreshed
        persistRecords()
    }

    private func persistRecords() {
        if let data = try? JSONEncoder().encode(records), defaults.data(forKey: "library.records") != data {
            defaults.set(data, forKey: "library.records")
        }
    }

    private func replaceLegacyPaths() {
        defaults.set(records.map(\.path), forKey: "library.apps")
        persistRecords()
    }

    func add() {
        let panel = NSOpenPanel()
        panel.title = "Add Native Game Apps"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        _ = add(panel.urls)
    }

    @discardableResult func add(_ urls: [URL]) -> String? {
        var result: String?
        var failures: [String] = []
        for url in urls where url.isFileURL {
            if let previous = games.first(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
                result = previous.id
                continue
            }
            guard let bundle = GameBundle(url) else {
                failures.append("\(url.lastPathComponent) is missing a readable app bundle.")
                continue
            }
            if let issue = bundle.issue {
                failures.append("\(bundle.name) — \(issue)")
                continue
            }
            let record = LibraryRecord(url: url)
            if !records.contains(where: { $0.id == record.id }) { records.append(record) }
            result = record.id
        }
        replaceLegacyPaths()
        load()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        return result
    }

    func locate(_ game: Game) {
        let panel = NSOpenPanel()
        panel.title = "Locate \(game.title)"
        panel.prompt = "Connect"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let candidate = GameBundle(url) else { return }
        if let expected = game.record.titleID {
            guard candidate.titleID == expected else { error = "Choose the same game title."; return }
        } else if let expected = game.record.bundleID {
            guard candidate.bundleID == expected else { error = "Choose the original application."; return }
        } else if candidate.name != game.title {
            error = "Choose the application named \(game.title)."
            return
        }
        if let issue = candidate.issue { error = issue; return }
        let updated = LibraryRecord(url: url, id: game.id)
        records.removeAll { $0.id == game.id || $0.path == url.path }
        records.append(updated)
        replaceLegacyPaths()
        load()
    }

    func play(_ game: Game) {
        let current = resolve(game.record, automatic: game.automatic)
        guard current.issue == nil else { error = current.issue; load(); return }
        let config = NSWorkspace.OpenConfiguration()
        if current.bundle?.isPortable != true {
            config.environment = GamePreferences(current).launchEnvironment
        }
        NSWorkspace.shared.openApplication(at: current.url, configuration: config) { _, failure in
            Task { @MainActor in
                if let failure { self.error = failure.localizedDescription }
                else {
                    self.launches[game.id] = Date().timeIntervalSince1970
                    self.defaults.set(self.launches, forKey: "library.launches")
                }
            }
        }
    }

    func toggleFavorite(_ game: Game) {
        if favorites.contains(game.id) { favorites.remove(game.id) } else { favorites.insert(game.id) }
        defaults.set(Array(favorites), forKey: "library.favorites")
    }

    func lastPlayed(_ game: Game) -> String {
        guard let time = launches[game.id] else { return "Never played" }
        return Date(timeIntervalSince1970: time).formatted(date: .abbreviated, time: .shortened)
    }

    func remove(_ game: Game) {
        if game.automatic { defaults.set(true, forKey: "library.hideAutomaticGame") }
        records.removeAll { $0.id == game.id }
        replaceLegacyPaths()
        load()
    }

    func reveal(_ game: Game) {
        guard fm.fileExists(atPath: game.url.path) else { error = game.issue; return }
        NSWorkspace.shared.activateFileViewerSelecting([game.url])
    }

    func isRunning(_ game: Game) -> Bool {
        let ids = games.filter { $0.id == game.id || (game.titleID != nil && $0.titleID == game.titleID) }
            .compactMap { $0.bundle?.bundleID }
        return ids.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    func revealSaves(_ game: Game) {
        guard let folder = game.saveRoot, fm.fileExists(atPath: folder.path) else {
            error = "The save folder appears after you start the game."
            return
        }
        NSWorkspace.shared.open(folder)
    }

    func backupSaves(_ game: Game) {
        guard let folder = game.saveRoot else { return }
        guard !isRunning(game) else { error = "Quit the game before making a save backup."; return }
        let saves = ["save", "save_device"].filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard !saves.isEmpty else { error = "There are no local saves for this game."; return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Save Backup Destination"
        panel.prompt = "Back Up"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let location = panel.url else { return }
        guard !isRunning(game) else { error = "Quit the game before making a save backup."; return }
        let backup = location.appendingPathComponent("\(game.titleID ?? "Game") Save \(UUID().uuidString.prefix(8))", isDirectory: true)
        busy.insert(game.id)
        Task {
            let failure = await Task.detached(priority: .utility) { () -> String? in
                let fm = FileManager.default
                let staged = location.appendingPathComponent(".switch2mac-save-\(UUID().uuidString)", isDirectory: true)
                defer { try? fm.removeItem(at: staged) }
                do {
                    try fm.createDirectory(at: staged, withIntermediateDirectories: false)
                    for name in saves {
                        try fm.copyItem(at: folder.appendingPathComponent(name), to: staged.appendingPathComponent(name))
                    }
                    try fm.moveItem(at: staged, to: backup)
                    return nil
                } catch { return error.localizedDescription }
            }.value
            busy.remove(game.id)
            if let failure { error = failure } else {
                notice = "Saved \(backup.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([backup])
            }
        }
    }

    private func iconFile(_ game: Game) -> URL {
        let artwork = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Switch2Mac/Artwork", isDirectory: true)
        let id = SHA256.hash(data: Data(game.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return artwork.appendingPathComponent(id).appendingPathExtension("png")
    }

    func icon(_ game: Game) -> NSImage {
        let key = game.id as NSString
        if let image = icons.object(forKey: key) { return image }
        let image = NSImage(contentsOf: iconFile(game)) ?? NSWorkspace.shared.icon(forFile: game.url.path)
        icons.setObject(image, forKey: key)
        return image
    }

    func chooseIcon(_ game: Game) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Game Icon"
        panel.prompt = "Use Image"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary),
              let png = squareIcon(thumbnail) else {
            error = "Choose a readable image such as a PNG or JPEG."
            return
        }
        do {
            let destination = iconFile(game)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            icons.removeObject(forKey: game.id as NSString)
            artworkRevision += 1
        } catch { self.error = error.localizedDescription }
    }

    private func squareIcon(_ image: CGImage) -> Data? {
        let side = 512
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height), canvas = CGFloat(side)
        let scale = canvas / max(width, height)
        let rect = CGRect(x: (canvas - width * scale) / 2, y: (canvas - height * scale) / 2,
                          width: width * scale, height: height * scale)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let square = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: square).representation(using: .png, properties: [:])
    }

    func resetIcon(_ game: Game) {
        let url = iconFile(game)
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
            icons.removeObject(forKey: game.id as NSString)
            artworkRevision += 1
        }
        catch { self.error = error.localizedDescription }
    }

    func exportPortable(_ game: Game) {
        guard game.issue == nil, game.titleID != nil, !busy.contains(game.id) else { return }
        let helper = Bundle.main.url(forResource: "portable_game", withExtension: "py", subdirectory: "Builder")
            ?? project.appendingPathComponent("tools/portable_game.py")
        guard fm.isReadableFile(atPath: helper.path) else { error = "The portable export tool is missing."; return }
        let panel = NSSavePanel()
        panel.title = "Export a Standalone Game App"
        panel.message = "Export to the same APFS volume. You can move the finished application to another drive afterward."
        panel.prompt = "Export"
        panel.directoryURL = game.url.deletingLastPathComponent()
        panel.allowedContentTypes = [.applicationBundle]
        panel.nameFieldStringValue = "\(game.title) Portable.app"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let output = panel.url else { return }
        guard !fm.fileExists(atPath: output.path) else {
            error = "Choose a new destination name for the exported app."
            return
        }
        var args = [helper.path, "pack", "--source", game.url.path, "--output", output.path]
        let icon = iconFile(game)
        if fm.fileExists(atPath: icon.path) { args += ["--icon", icon.path] }
        let arguments = args
        busy.insert(game.id)
        Task {
            let failure = await Task.detached(priority: .utility) { () -> String? in
                let task = Process()
                let pipe = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                task.arguments = arguments
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    guard task.terminationStatus == 0 else {
                        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? "Export stopped before creating the app." : String(text.suffix(1500))
                    }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            busy.remove(game.id)
            if let failure { error = failure } else {
                add([output])
                notice = "Exported \(output.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
        }
    }
}
