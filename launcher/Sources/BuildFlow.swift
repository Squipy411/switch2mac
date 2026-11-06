import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin

enum BuildSystem: String, CaseIterable, Identifiable {
    case switch1 = "Switch 1"
    case switch2 = "Switch 2"
    var id: String { rawValue }
}

enum BuildEngine: String, CaseIterable, Identifiable {
    case nx2apple = "NX2Apple"
    case switch2mac = "Switch2Mac"
    var id: String { rawValue }
}

struct BuildRequest {
    let system: BuildSystem
    let engine: BuildEngine
    let source: URL
    let updates: [URL]
    let dlc: [URL]
    let keys: URL?
    let name: String
    let buildFolder: URL
    let buildVolumeUUID: String?
    let outputFolder: URL
    let outputVolumeUUID: String?
    let inputVolumeUUIDs: [String: String]
    let allowOtherMetal: Bool
}

private struct BuildLocation: Codable, Equatable {
    let path: String
    let volumeUUID: String?
    let mountPath: String?

    init(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        path = resolved.path
        var existing = resolved
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        let values = try? existing.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        volumeUUID = values?.volumeUUIDString
        mountPath = values?.volume?.path
    }

    var url: URL {
        if let volumeUUID, let mountPath, mountPath.hasPrefix("/Volumes/"), path == mountPath || path.hasPrefix(mountPath + "/"),
           let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: [.skipHiddenVolumes]),
           let mounted = volumes.first(where: { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == volumeUUID }) {
            let relative = String(path.dropFirst(mountPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? mounted : mounted.appendingPathComponent(relative, isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static let internalDefault: BuildLocation = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let checkout = home.appendingPathComponent("Projects/Development/switch2mac", isDirectory: true)
        let folder = FileManager.default.fileExists(atPath: checkout.appendingPathComponent("switch2mac.py").path)
            ? checkout.appendingPathComponent("work/Native Builds", isDirectory: true)
            : home.appendingPathComponent("Library/Application Support/Switch2Mac/Builds", isDirectory: true)
        return BuildLocation(folder)
    }()

    static func saved(_ key: String) -> BuildLocation? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(_ key: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: key) }
    }
}

@MainActor final class BuildManager: ObservableObject {
    @Published private(set) var state = "idle"
    @Published private(set) var stage = "No build started"
    @Published private(set) var message = "Choose Build Game to compile your own game files into a Mac app."
    @Published private(set) var fraction: Double?
    @Published private(set) var log = ""
    @Published private(set) var appURL: URL?
    @Published private(set) var buildDirectory: URL?
    @Published private(set) var gameName = ""
    @Published private(set) var systemName = ""
    @Published private(set) var engineName = ""
    @Published private(set) var updatedAt: Date?
    @Published private var nx2ApplePath = UserDefaults.standard.string(forKey: "builder.nx2apple")

    private var timer: Timer?
    private var activityDirectory: URL?
    private var lastStatus: Data?
    private var workerPID: Int32?
    private var logModified: Date?
    private var logSize: Int?
    private var loadedManifest: URL?
    var isActive: Bool { ["starting", "running", "cancelling"].contains(state) }

    init() {
        if let path = UserDefaults.standard.string(forKey: "builder.currentDirectory") {
            buildDirectory = URL(fileURLWithPath: path)
            activityDirectory = buildDirectory
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func backend(_ engine: BuildEngine) -> URL {
        switch engine {
        case .switch2mac: project
        case .nx2apple: URL(fileURLWithPath: nx2ApplePath ?? project.appendingPathComponent(".tools/nx2apple").path)
        }
    }

    func python(_ engine: BuildEngine) -> URL {
        switch engine {
        case .switch2mac: project.appendingPathComponent(".venv/bin/python")
        case .nx2apple: project.appendingPathComponent(".tools/nx2apple-venv/bin/python")
        }
    }

    func available(_ engine: BuildEngine) -> Bool {
        let root = backend(engine)
        let py = python(engine)
        guard FileManager.default.isExecutableFile(atPath: py.path) else { return false }
        if engine == .switch2mac { return FileManager.default.fileExists(atPath: root.appendingPathComponent("switch2mac.py").path) }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("engine/scripts/build_ipa_from_nsp.py").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/build_ipa_from_nsp.py").path)
    }

    func chooseNX2Apple() {
        let panel = NSOpenPanel()
        panel.title = "Choose the NX2Apple engine folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            nx2ApplePath = url.path
            UserDefaults.standard.set(url.path, forKey: "builder.nx2apple")
        }
    }

    func start(_ request: BuildRequest) throws {
        guard !isActive else { throw BuildStartError("A build is already running. Stop it or wait for it to finish first.") }
        let service = Bundle.main.url(forResource: "build_service", withExtension: "py", subdirectory: "Builder")
        guard let service else { throw BuildStartError("The build service is missing from this app.") }
        guard available(request.engine) else { throw BuildStartError("The \(request.engine.rawValue) build engine or its Python environment is missing.") }

        let safeName = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !safeName.isEmpty, !safeName.hasPrefix("."), safeName.utf8.count < 240,
              safeName.rangeOfCharacter(from: .controlCharacters) == nil else { throw BuildStartError("Enter a valid name for the Mac app.") }

        let root = request.buildFolder.standardizedFileURL
        let key = "\(request.system.rawValue)|\(request.engine.rawValue)|\(request.source.standardizedFileURL.path)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
        let jobDirectory = root.appendingPathComponent(".builddata/\(digest)", isDirectory: true)
        let appPath = request.outputFolder.appendingPathComponent("\(safeName).app", isDirectory: true).path
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let activity = appSupport.appendingPathComponent("Switch2Mac/Build Activity/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: activity, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let job: [String: Any] = [
            "system": request.system.rawValue,
            "engine": request.engine.rawValue == "Switch2Mac" ? "switch2mac" : "nx2apple",
            "source": request.source.standardizedFileURL.path,
            "updates": request.updates.map { $0.standardizedFileURL.path },
            "dlc": request.dlc.map { $0.standardizedFileURL.path },
            "keys": request.keys?.standardizedFileURL.path ?? "",
            "name": safeName,
            "app_path": appPath,
            "directory": jobDirectory.path,
            "workspace_root": root.path,
            "state_directory": activity.path,
            "publish_app": true,
            "build_volume_uuid": request.buildVolumeUUID ?? "",
            "output_volume_uuid": request.outputVolumeUUID ?? "",
            "input_volume_uuids": request.inputVolumeUUIDs,
            "backend": backend(request.engine).standardizedFileURL.path,
            "python": python(request.engine).path,
            "allow_other_metal": request.allowOtherMetal
        ]
        let jobURL = activity.appendingPathComponent("job.json")
        let data = try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: jobURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobURL.path)

        buildDirectory = jobDirectory
        activityDirectory = activity
        lastStatus = nil
        workerPID = nil
        logModified = nil
        logSize = nil
        loadedManifest = activity
        UserDefaults.standard.set(activity.path, forKey: "builder.currentDirectory")
        gameName = safeName
        systemName = request.system.rawValue
        engineName = request.engine.rawValue
        state = "starting"
        stage = "Starting build"
        message = "Your files stay on this Mac. The build can continue if you close this window."
        fraction = nil
        updatedAt = nil
        log = ""
        appURL = nil
        startSupervisor(service: service, job: jobURL, python: python(request.engine))
    }

    func stop() {
        guard let activityDirectory, ["starting", "running"].contains(state) else { return }
        let cancel = activityDirectory.appendingPathComponent("cancel.request")
        FileManager.default.createFile(atPath: cancel.path, contents: Data())
        state = "cancelling"
        stage = "Stopping build"
        message = "The current step will stop and keep its work files."
    }

    func refresh() {
        guard let activityDirectory else { return }
        let statusURL = activityDirectory.appendingPathComponent("status.json")
        if let data = try? Data(contentsOf: statusURL), data != lastStatus,
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lastStatus = data
            workerPID = raw["pid"] as? Int32
            state = raw["state"] as? String ?? state
            stage = raw["stage"] as? String ?? stage
            message = raw["message"] as? String ?? message
            fraction = raw["fraction"] as? Double
            if let value = raw["updated"] as? Double { updatedAt = Date(timeIntervalSince1970: value) }
            if state == "completed", let path = raw["app_path"] as? String { appURL = URL(fileURLWithPath: path) }
            if let path = raw["workspace"] as? String { buildDirectory = URL(fileURLWithPath: path, isDirectory: true) }
        }
        if isActive, let workerPID, kill(workerPID, 0) == -1, errno == ESRCH {
            state = "failed"
            stage = "Build interrupted"
            message = "The compiler stopped. Retry to reuse its build files."
        }
        if state == "completed", let appURL, FileManager.default.fileExists(atPath: appURL.path) {
            var paths = UserDefaults.standard.stringArray(forKey: "library.apps") ?? []
            if !paths.contains(appURL.path) {
                paths.append(appURL.path)
                UserDefaults.standard.set(paths, forKey: "library.apps")
            }
        }
        let logURL = activityDirectory.appendingPathComponent("build.log")
        if let values = try? logURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
           values.contentModificationDate != logModified || values.fileSize != logSize,
           let handle = try? FileHandle(forReadingFrom: logURL) {
            logModified = values.contentModificationDate
            logSize = values.fileSize
            let end = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: end > 24000 ? end - 24000 : 0)
            if let data = try? handle.readToEnd() { log = String(decoding: data, as: UTF8.self) }
            try? handle.close()
        }
        if loadedManifest != activityDirectory,
           let jobData = try? Data(contentsOf: activityDirectory.appendingPathComponent("job.json")),
           let job = try? JSONSerialization.jsonObject(with: jobData) as? [String: Any] {
            loadedManifest = activityDirectory
            gameName = job["name"] as? String ?? gameName
            systemName = job["system"] as? String ?? systemName
            engineName = (job["engine"] as? String == "nx2apple") ? "NX2Apple" : "Switch2Mac"
        }
    }

    func reveal() {
        if state == "completed", let appURL, FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } else if let buildDirectory {
            if FileManager.default.fileExists(atPath: buildDirectory.path) {
                NSWorkspace.shared.open(buildDirectory)
            } else if let activityDirectory {
                NSWorkspace.shared.open(activityDirectory)
            }
        }
    }

    private func startSupervisor(service: URL, job: URL, python: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = python
            process.arguments = [service.path, "start", job.path]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let result = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    guard let self else { return }
                    if process.terminationStatus != 0 {
                        self.state = "failed"
                        self.stage = "Could not start build"
                        self.message = text.isEmpty ? "The build supervisor stopped before it could start." : text
                    } else {
                        self.refresh()
                    }
                }
            } catch {
                Task { @MainActor in
                    self?.state = "failed"
                    self?.stage = "Could not start build"
                    self?.message = error.localizedDescription
                }
            }
        }
    }
}

struct BuildStartError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

struct BuildWizard: View {
    @ObservedObject var manager: BuildManager
    @Environment(\.dismiss) private var dismiss
    @State private var system: BuildSystem = .switch2
    @State private var switch2Engine: BuildEngine = .switch2mac
    @State private var source: URL?
    @State private var updates: [URL] = []
    @State private var dlc: [URL] = []
    @State private var keys: URL?
    @State private var name = ""
    @State private var buildLocation = BuildLocation.saved("builder.workspaceLocation") ?? .internalDefault
    @State private var outputLocation = BuildLocation.saved("builder.appLocation") ?? .internalDefault
    @State private var sharedLocation = !UserDefaults.standard.bool(forKey: "builder.separateAppLocation")
    @State private var allowOtherMetal = false
    @State private var inputVolumeUUIDs: [String: String] = [:]
    @State private var error: String?

    private var engine: BuildEngine { system == .switch1 ? .nx2apple : switch2Engine }
    private var sourceIsArchive: Bool { source?.hasDirectoryPath == false }
    private var sourceLooksExtracted: Bool {
        guard let source, source.hasDirectoryPath else { return false }
        return [source, source.appendingPathComponent("base")].contains { exefsProgramID($0) != nil }
    }
    private var needsKeys: Bool { system == .switch1 && source != nil && !sourceLooksExtracted }
    private var sourceCompatible: Bool { system != .switch2 || switch2Engine != .switch2mac || sourceLooksExtracted }
    private var canStart: Bool { source != nil && sourceCompatible && !manager.isActive && manager.available(engine) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!needsKeys || keys != nil) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                platformSection
                gameFilesSection
                macAppSection
            }
            .dropDestination(for: URL.self) { urls, _ in importSources(urls) }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Build Mac App", systemImage: "hammer") { begin() }
                    .buttonStyle(.glassProminent)
                    .disabled(!canStart)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 520, idealHeight: 650)
        .alert("Build setup", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onChange(of: system) { _, _ in
            if source != nil { name = defaultName(source) }
            updates = []; dlc = []; keys = nil
        }
        .onChange(of: switch2Engine) { _, _ in
            if source != nil { name = defaultName(source) }
        }
    }

    private var platformSection: some View {
        Section {
            Text("Build a standalone Mac app using your own game files.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("System", selection: $system) {
                ForEach(BuildSystem.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if system == .switch2 {
                Picker("Build engine", selection: $switch2Engine) {
                    Text("Switch2Mac · supported base games").tag(BuildEngine.switch2mac)
                    Text("NX2Apple · profiled titles").tag(BuildEngine.nx2apple)
                }
                Text(switch2Engine == .switch2mac
                     ? "Uses the extracted base version registered in your Switch2Mac engine. First builds need room for a RomFS image and shader cache."
                     : "Uses NX2Apple for Switch 2 releases that have a game profile.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Uses NX2Apple for Switch 1 titles with a compatible game profile. Archived files need your own prod.keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Engine status") {
                Label(manager.available(engine) ? "Installed" : "Not found",
                      systemImage: manager.available(engine) ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(manager.available(engine) ? Color.secondary : Color.orange)
            }
            if !manager.available(engine) && engine == .nx2apple {
                Button("Choose NX2Apple Folder…") { manager.chooseNX2Apple() }
            }
            Text("The engine checks the title, toolchain and selected drives before compiling.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Platform") }
    }

    private var gameFilesSection: some View {
        Section("Game files") {
            Text("Choose or drop a game folder, an extracted file, or a supported container.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source?.lastPathComponent ?? "No game files selected")
                        .lineLimit(1).truncationMode(.middle)
                    Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(source == nil ? "Choose…" : "Change…", systemImage: "folder") { chooseSource() }
            }
            if system == .switch1 && needsKeys {
                fileRow("Update files", count: updates.count) {
                    if let files = chooseFiles(title: "Choose Switch 1 update files", extensions: ["nsp", "xci", "nsz", "xcz"]) {
                        updates = files
                        rememberVolumes(files)
                    }
                } clear: { updates = [] }
                fileRow("DLC files", count: dlc.count) {
                    if let files = chooseFiles(title: "Choose Switch 1 DLC files", extensions: ["nsp", "xci", "nsz", "xcz"]) {
                        dlc = files
                        rememberVolumes(files)
                    }
                } clear: { dlc = [] }
                if !sourceIsArchive {
                    Text("Packages in the selected folder and its base, updates and dlc folders are included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                keysRow
            } else if source != nil && engine == .nx2apple {
                Text("Updates and DLC can be included in a NUP or alongside base/ in a compatible extracted folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var keysRow: some View {
        HStack {
            Label("prod.keys", systemImage: "key.horizontal")
            Spacer()
            if let keys { Text(keys.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Button(keys == nil ? "Choose…" : "Change…") { chooseKeys() }
        }
    }

    private var macAppSection: some View {
        Section("Mac app") {
            TextField(engine == .switch2mac ? "App filename" : "App name", text: $name)
            locationRow("Build workspace", location: buildLocation) {
                if let chosen = chooseLocation(title: "Choose a build workspace", current: buildLocation) { buildLocation = chosen }
            }
            if buildLocation != .internalDefault {
                Button("Use Internal Storage", systemImage: "internaldrive") { buildLocation = .internalDefault }
            }
            Toggle("Save the app beside the build workspace", isOn: $sharedLocation)
            if !sharedLocation {
                locationRow("Finished app", location: outputLocation) {
                    if let chosen = chooseLocation(title: "Choose where to save the finished Mac app", current: outputLocation) { outputLocation = chosen }
                }
            }
            Text("The workspace keeps files for faster retries. Use an APFS drive for fast copies when the app and workspace share a volume.")
                .font(.caption).foregroundStyle(.secondary)
            if engine == .nx2apple {
                Toggle("Allow a different Xcode Metal version", isOn: $allowOtherMetal)
                Text("Some graphics profiles require a specific Xcode version. This option lets the engine try another one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func locationRow(_ title: String, location: BuildLocation, choose: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: "externaldrive")
                Text(location.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Choose…", action: choose).accessibilityLabel("Choose \(title.lowercased())")
        }
    }

    private var sourceDescription: String {
        if source == nil {
            if system == .switch2 && switch2Engine == .switch2mac { return "Extracted exefs and romfs for a supported base version" }
            if system == .switch2 { return "Profiled game folder or .nup container" }
            return "Extracted folder or NSP, XCI, NSZ or XCZ archive"
        }
        if system == .switch2 && switch2Engine == .switch2mac { return "Switch2Mac builds the supported base ExeFS and RomFS." }
        if system == .switch2 { return "NX2Apple needs a supported profile for this Switch 2 game." }
        if sourceLooksExtracted { return "Extracted game files selected · no keys needed." }
        return sourceIsArchive ? "Archive selected · add your own prod.keys below." : "Game archive folder selected · add your own prod.keys below."
    }

    @ViewBuilder private func fileRow(_ title: String, count: Int, action: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: "doc")
            Spacer()
            if count > 0 {
                Text("\(count) selected").font(.caption).foregroundStyle(.secondary)
                Button("Clear", action: clear).accessibilityLabel("Clear \(title.lowercased())")
            }
            Button(count == 0 ? "Choose…" : "Change…", action: action)
        }
    }

    private func defaultName(_ url: URL?) -> String {
        guard let url else { return "" }
        if system == .switch2 && switch2Engine == .switch2mac,
           let root = extractedRoot(for: url), let title = exefsProgramID(root), let name = switch2MacName(title) { return name }
        return url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose your game files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = importSources([url])
        }
    }

    private func extractedRoot(for url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            for root in [candidate, candidate.appendingPathComponent("base", isDirectory: true)] {
                var isDirectory: ObjCBool = false
                let files = FileManager.default
                if files.fileExists(atPath: root.appendingPathComponent("exefs/main").path),
                   files.fileExists(atPath: root.appendingPathComponent("exefs/main.npdm").path) {
                    if files.fileExists(atPath: root.appendingPathComponent("romfs").path, isDirectory: &isDirectory), isDirectory.boolValue { return root }
                    if root.lastPathComponent == "base", files.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("updates").path) { return root }
                }
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func exefsProgramID(_ root: URL) -> String? {
        guard let metadata = try? Data(contentsOf: root.appendingPathComponent("exefs/main.npdm")),
              metadata.count >= 0x74, metadata.prefix(4) == Data("META".utf8) else { return nil }
        let offset = Int(metadata.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0x70, as: UInt32.self)) })
        guard offset <= metadata.count - 0x18,
              metadata[offset..<(offset + 4)] == Data("ACI0".utf8) else { return nil }
        let titleID = metadata.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 0x10, as: UInt64.self)) }
        return String(format: "%016llX", titleID)
    }

    private func switch2MacName(_ title: String) -> String? {
        let games = manager.backend(.switch2mac).appendingPathComponent("games")
        let folders = (try? FileManager.default.contentsOfDirectory(at: games, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for folder in folders {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("game.json")),
               let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               metadata["title_id"]?.uppercased() == title { return metadata["name"] }
        }
        return nil
    }

    @discardableResult
    private func importSources(_ urls: [URL]) -> Bool {
        guard let first = urls.first, urls.allSatisfy(\.isFileURL) else { return false }
        if let root = extractedRoot(for: first) {
            guard urls.allSatisfy({ extractedRoot(for: $0)?.path == root.path }) else {
                error = "Choose files from one extracted game at a time."
                return false
            }
            if let title = exefsProgramID(root), switch2MacName(title) != nil {
                system = .switch2
                switch2Engine = .switch2mac
            } else if let title = exefsProgramID(root) {
                system = title.hasPrefix("04") ? .switch2 : .switch1
                if system == .switch2 { switch2Engine = .nx2apple }
            }
            let parent = root.deletingLastPathComponent()
            let includesAddons = ["updates", "dlc"].contains { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
            let folder = root.lastPathComponent == "base" && (first.standardizedFileURL.path == parent.path || includesAddons) ? parent : root
            source = URL(fileURLWithPath: folder.path, isDirectory: true)
        } else if urls.count == 1, first.pathExtension.lowercased() == "nup" {
            system = .switch2
            switch2Engine = .nx2apple
            source = first
        } else if urls.count == 1, isSwitch1PackageSelection(first) {
            system = .switch1
            source = first
        } else if urls.count == 1, first.hasDirectoryPath {
            switch2Engine = .nx2apple
            source = first
        } else {
            error = "Choose an NSP, XCI, NSZ or XCZ for Switch 1, or a NUP or extracted game folder for Switch 2."
            return false
        }
        name = defaultName(source)
        updates = []; dlc = []; keys = nil
        inputVolumeUUIDs = [:]
        if let source { rememberVolumes([source]) }
        return true
    }

    private func isSwitch1PackageSelection(_ url: URL) -> Bool {
        let extensions = ["nsp", "xci", "nsz", "xcz"]
        if !url.hasDirectoryPath { return extensions.contains(url.pathExtension.lowercased()) }
        return [url, url.appendingPathComponent("base"), url.appendingPathComponent("updates"), url.appendingPathComponent("dlc")].contains { folder in
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return children.contains { extensions.contains($0.pathExtension.lowercased()) }
        }
    }

    private func chooseFiles(title: String, extensions: [String]) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.urls : nil
    }

    private func chooseKeys() {
        let panel = NSOpenPanel()
        panel.title = "Choose your own prod.keys file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url {
            keys = url
            rememberVolumes([url])
        }
    }

    private func rememberVolumes(_ files: [URL]) {
        for file in files {
            inputVolumeUUIDs[file.standardizedFileURL.path] = BuildLocation(file).volumeUUID
        }
    }

    private func chooseLocation(title: String, current: BuildLocation) -> BuildLocation? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.directoryURL = current.url
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return BuildLocation(url)
    }

    private func begin() {
        guard let source else { return }
        let selectedSource = engine == .switch2mac ? extractedRoot(for: source) ?? source : source
        let appName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = sharedLocation ? buildLocation : outputLocation
        var selectedVolumes = inputVolumeUUIDs
        selectedVolumes[selectedSource.standardizedFileURL.path] = inputVolumeUUIDs[source.standardizedFileURL.path]
        do {
            try manager.start(BuildRequest(system: system, engine: engine, source: selectedSource, updates: updates, dlc: dlc,
                                           keys: keys, name: appName, buildFolder: buildLocation.url, buildVolumeUUID: buildLocation.volumeUUID,
                                           outputFolder: output.url, outputVolumeUUID: output.volumeUUID, inputVolumeUUIDs: selectedVolumes,
                                           allowOtherMetal: allowOtherMetal))
            buildLocation.save("builder.workspaceLocation")
            outputLocation.save("builder.appLocation")
            UserDefaults.standard.set(!sharedLocation, forKey: "builder.separateAppLocation")
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
