import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum Destination: String, CaseIterable, Identifiable {
    case all = "All Games"
    case favorites = "Favourites"
    case ready = "Ready to Play"
    case external = "External Drives"
    case activity = "Build Activity"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .favorites: "star"
        case .ready: "play.circle"
        case .external: "externaldrive"
        case .activity: "hammer"
        }
    }
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "Title A–Z"
    case reverseTitle = "Title Z–A"
    case recent = "Recently Launched"
    var id: Self { self }
}

private struct SettingsRequest: Identifiable {
    let game: Game
    let page: GameSettingsPage
    var id: String { game.id + page.rawValue }
}

struct LibraryView: View {
    @ObservedObject var library: Library
    @ObservedObject var build: BuildManager
    @AppStorage("library.grid") private var grid = false
    @AppStorage("library.inspector") private var inspector = true
    @AppStorage("library.metadata") private var metadata = true
    @AppStorage("library.theme") private var theme = "System"
    @State private var destination: Destination? = .all
    @State private var selected: String?
    @State private var query = ""
    @State private var showingBuild = false
    @State private var sort: LibrarySort = .title
    @State private var settings: SettingsRequest?
    @Environment(\.openSettings) private var openSettings

    private var selection: Game? { filtered.first { $0.id == selected } }
    private var isActivity: Bool { destination == .activity }
    private var runningBuild: Bool { ["starting", "running", "cancelling"].contains(build.state) }
    private var appearance: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview-light") { return .light }
        if arguments.contains("--preview-dark") { return .dark }
        #endif
        return theme == "Dark" ? .dark : (theme == "Light" ? .light : nil)
    }

    private var filtered: [Game] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = library.games.filter { game in
            let found = term.isEmpty || game.title.localizedCaseInsensitiveContains(term)
                || game.titleID?.localizedCaseInsensitiveContains(term) == true
                || game.location.localizedCaseInsensitiveContains(term)
            guard found else { return false }
            switch destination {
            case .favorites: return library.favorites.contains(game.id)
            case .ready: return game.issue == nil
            case .external: return game.record.volumeName != nil
            default: return true
            }
        }
        return matches.sorted { first, second in
            let a = first.title.localizedStandardCompare(second.title)
            if sort == .recent {
                let x = library.launches[first.id, default: 0], y = library.launches[second.id, default: 0]
                if x != y { return x > y }
            }
            if a == .orderedSame { return first.id < second.id }
            return sort == .reverseTitle ? a == .orderedDescending : a == .orderedAscending
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section("Library") {
                    ForEach([Destination.all, .favorites, .ready, .external]) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Build") {
                    Label(Destination.activity.rawValue, systemImage: Destination.activity.symbol)
                        .badge(runningBuild ? 1 : 0)
                        .tag(Destination.activity)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 164, ideal: 185, max: 232)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if isActivity {
                        ActivityView(build: build, showBuild: { showingBuild = true })
                    } else {
                        libraryContent
                        Divider()
                        libraryFooter
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keep the detail column's AppKit split item stable while changing sections.
                if inspector && !isActivity {
                    Divider()
                    inspectorContent
                        .frame(width: 290)
                        .frame(maxHeight: .infinity)
                        .background(.bar)
                }
            }
            .navigationTitle(destination?.rawValue ?? "All Games")
            .toolbar { toolbar }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search library")
        .frame(minWidth: 820, minHeight: 520)
        .preferredColorScheme(appearance)
        .sheet(isPresented: $showingBuild) { BuildWizard(manager: build) }
        .sheet(item: $settings) { request in
            GameSettingsView(game: request.game, library: library, page: request.page)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchMacBuildRequested)) { _ in showingBuild = true }
        .onChange(of: build.state) { _, state in
            if ["starting", "running", "cancelling"].contains(state) { destination = .activity }
            if state == "completed" { library.load() }
        }
        .onChange(of: destination) { _, value in if value != .activity { matchSelection() } }
        .onChange(of: filtered.map(\.id)) { _, _ in if !isActivity { matchSelection() } }
        .alert("Switch2Mac", isPresented: Binding(get: { library.error != nil || library.notice != nil }, set: { showing in
            if !showing { library.error = nil; library.notice = nil }
        })) {
            Button("OK") { library.error = nil; library.notice = nil }
        } message: { Text(library.error ?? library.notice ?? "") }
        .onAppear { configurePreview() }
        .task { await verifyNavigation() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button("Build", systemImage: "hammer") { showingBuild = true }
                .help("Build a native Mac game from your own game files")
        }
        if !isActivity {
            ToolbarItemGroup {
                Button("Add", systemImage: "plus") { library.add() }.help("Add a game app")
                Menu {
                    Picker("Layout", selection: $grid) {
                        Label("List", systemImage: "list.bullet").tag(false)
                        Label("Grid", systemImage: "square.grid.2x2").tag(true)
                    }
                    Divider()
                    Picker("Sort", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("View", systemImage: grid ? "square.grid.2x2" : "list.bullet") }
                .help("Layout and sort order")
            }
            ToolbarItemGroup {
                if !inspector {
                    Button("Play", systemImage: "play.fill") {
                        if let selection { library.play(selection) }
                    }
                    .disabled(selection?.issue != nil || selection == nil)
                }
                Button("Game Inspector", systemImage: "sidebar.trailing") { inspector.toggle() }
                    .help("Show or hide the game inspector")
            }
        }
    }

    @ViewBuilder private var libraryContent: some View {
        Group {
            if filtered.isEmpty {
                if library.games.isEmpty && query.isEmpty && destination == .all {
                    ContentUnavailableView {
                        Label("Your Game Library", systemImage: "gamecontroller")
                    } description: {
                        Text("Build a native Mac game, or add an app you already have.")
                    } actions: {
                        Button("Build Game…", systemImage: "hammer") { showingBuild = true }.buttonStyle(.glassProminent)
                        Button("Add App…", systemImage: "plus") { library.add() }.buttonStyle(.glass)
                    }
                } else {
                    ContentUnavailableView(query.isEmpty ? "No Games Here" : "No Matching Games",
                                           systemImage: query.isEmpty ? "square.stack" : "magnifyingglass",
                                           description: Text(query.isEmpty ? "Choose another collection from the sidebar." : "Search by title, title ID, or drive name."))
                }
            } else if grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 230), spacing: 20)], spacing: 16) {
                        ForEach(filtered) { game in
                            Button { selected = game.id } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    GameIcon(image: library.icon(game), size: 76)
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    Text(game.title).font(.headline).lineLimit(1)
                                    StatusLabel(game: game).font(.caption)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(selected == game.id ? Color.accentColor.opacity(0.13) : .clear, in: .rect(cornerRadius: 13))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { gameMenu(game) }
                            .accessibilityAddTraits(selected == game.id ? .isSelected : [])
                        }
                    }.padding(20)
                }
            } else {
                Table(filtered, selection: $selected) {
                    TableColumn("Game") { game in
                        HStack(spacing: 11) {
                            GameIcon(image: library.icon(game), size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(game.title).fontWeight(.medium).lineLimit(1)
                                Text(game.bundle?.isPortable == true ? "Standalone game" : game.location)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if library.favorites.contains(game.id) {
                                Image(systemName: "star.fill").foregroundStyle(.secondary).font(.caption2).accessibilityLabel("Favourite")
                            }
                        }.padding(.vertical, 4)
                    }.width(min: 140, ideal: 250)
                    TableColumn("Version") { Text($0.version).monospacedDigit().foregroundStyle(.secondary) }.width(min: 52, ideal: 67, max: 94)
                    TableColumn("Status") { StatusLabel(game: $0) }.width(min: 92, ideal: 112)
                }
                .alternatingRowBackgrounds(.disabled)
                .contextMenu(forSelectionType: String.self) { selected in
                    if let game = filtered.first(where: { selected.contains($0.id) }) { gameMenu(game) }
                } primaryAction: { selected in
                    if let game = filtered.first(where: { selected.contains($0.id) }) { library.play(game) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let apps = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "app" }
            guard !apps.isEmpty else { return false }
            if let id = library.add(apps) { destination = .all; query = ""; selected = id }
            return true
        }
    }

    private var libraryFooter: some View {
        HStack {
            Text("\(filtered.count) \(filtered.count == 1 ? "game" : "games")").foregroundStyle(.secondary)
            Spacer()
            if runningBuild {
                Button { destination = .activity } label: {
                    Label(build.stage, systemImage: "hammer")
                }.buttonStyle(.plain)
            } else {
                let ready = filtered.filter { $0.issue == nil }.count
                if !filtered.isEmpty {
                    Label("\(ready) ready", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption).padding(.horizontal, 15).padding(.vertical, 9)
    }

    @ViewBuilder private var inspectorContent: some View {
        if let game = selection {
            GameInspector(game: game, library: library, metadata: metadata,
                          showSettings: { settings = SettingsRequest(game: game, page: $0) })
                .id(game.id)
        } else {
            ContentUnavailableView("Game Details", systemImage: "sidebar.trailing", description: Text("Select a game to see its details."))
        }
    }

    @ViewBuilder private func gameMenu(_ game: Game) -> some View {
        if game.issue == nil {
            Button("Play", systemImage: "play.fill") { library.play(game) }
            Button("Show in Finder", systemImage: "folder") { library.reveal(game) }
        } else {
            Button("Locate App…", systemImage: "magnifyingglass") { library.locate(game) }
        }
        Button(library.favorites.contains(game.id) ? "Remove Favourite" : "Add to Favourites", systemImage: "star") { library.toggleFavorite(game) }
        if game.titleID != nil {
            Button("Game Settings…", systemImage: "gearshape") { settings = SettingsRequest(game: game, page: .graphics) }
        }
        Divider()
        Button("Remove from Library", systemImage: "minus.circle") { library.remove(game) }
    }

    private func matchSelection() {
        if selection == nil { selected = (filtered.first { $0.issue == nil } ?? filtered.first)?.id }
    }

    private func configurePreview() {
        library.load()
        matchSelection()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--verify-internal-library"),
           let installed = library.games.first(where: { $0.url.path == "/Applications/Mario Kart World M2.app" || $0.url.path == "/Applications/Mario Kart World.app" }),
           installed.issue == nil, library.games.filter({ $0.url.path == installed.url.path }).count == 1 {
            print("INTERNAL_LIBRARY_OK")
            fflush(stdout)
        }
        if args.contains("--preview-settings") { openSettings() }
        if args.contains("--preview-build") { showingBuild = true }
        if args.contains("--preview-activity") { destination = .activity }
        if args.contains("--preview-search") { query = "No such game" }
        if args.contains("--preview-game-settings"), let selection {
            settings = SettingsRequest(game: selection, page: .graphics)
        }
        #endif
    }

    private func verifyNavigation() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--verify-activity-navigation") else { return }
        for _ in 0..<10 {
            destination = .activity
            try? await Task.sleep(for: .milliseconds(200))
            destination = .all
            try? await Task.sleep(for: .milliseconds(200))
        }
        destination = .activity
        print("ACTIVITY_NAVIGATION_OK")
        fflush(stdout)
        #endif
    }
}

private struct GameIcon: View {
    let image: NSImage
    let size: CGFloat
    var body: some View {
        Image(nsImage: image).resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size / 5))
            .accessibilityHidden(true)
    }
}

private struct StatusLabel: View {
    let game: Game
    var body: some View {
        Label(game.status, systemImage: game.issue == nil ? "checkmark.circle" : (game.status == "Offline" ? "externaldrive.badge.xmark" : "exclamationmark.circle"))
            .foregroundStyle(game.issue == nil ? Color.green : (game.status == "Offline" ? Color.secondary : Color.orange))
            .lineLimit(1)
    }
}

private struct GameInspector: View {
    let game: Game
    @ObservedObject var library: Library
    let metadata: Bool
    let showSettings: (GameSettingsPage) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    GameIcon(image: library.icon(game), size: 60)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(game.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(game.bundle?.isPortable == true ? "Standalone Mac app" : "Native Mac app")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if game.issue == nil {
                        Button {
                            library.play(game)
                        } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                    } else {
                        Button {
                            library.locate(game)
                        } label: { Label("Locate App…", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                    }
                    Button {
                        library.toggleFavorite(game)
                    } label: {
                        Image(systemName: library.favorites.contains(game.id) ? "star.fill" : "star")
                    }.buttonStyle(.glass)
                        .accessibilityLabel(library.favorites.contains(game.id) ? "Remove Favourite" : "Add to Favourites")
                }.controlSize(.large)

                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    LabeledContent("Status") { StatusLabel(game: game) }
                    LabeledContent("Version", value: game.version)
                    LabeledContent("Location", value: game.location)
                    LabeledContent("Last launched", value: library.lastPlayed(game))
                    if metadata, let id = game.titleID {
                        LabeledContent("Title ID") {
                            Text(id).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let issue = game.issue {
                        Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.font(.callout)

                if game.titleID != nil {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Game Settings").font(.headline)
                        ForEach(GameSettingsPage.allCases) { page in
                            Button { showSettings(page) } label: {
                                HStack {
                                    Label(page.rawValue, systemImage: page.symbol)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.disabled(game.issue != nil)
                }

                Divider()
                Menu {
                    Button("Show in Finder", systemImage: "folder") { library.reveal(game) }.disabled(game.issue != nil)
                    Button("Locate App…", systemImage: "magnifyingglass") { library.locate(game) }
                    Divider()
                    Button("Choose Game Icon…", systemImage: "photo") { library.chooseIcon(game) }
                    Button("Reset Library Icon", systemImage: "arrow.counterclockwise") { library.resetIcon(game) }
                    if game.titleID != nil {
                        Button("Export Standalone App…", systemImage: "square.and.arrow.up") { library.exportPortable(game) }
                            .disabled(game.issue != nil || library.busy.contains(game.id))
                    }
                } label: { Label("Manage Game", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if library.busy.contains(game.id) {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
            }
            .padding(19).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActivityView: View {
    @ObservedObject var build: BuildManager
    let showBuild: () -> Void

    private var running: Bool { ["starting", "running", "cancelling"].contains(build.state) }

    var body: some View {
        if build.state == "idle" {
            ContentUnavailableView {
                Label("No Active Build", systemImage: "hammer")
            } description: {
                Text("Build progress and compiler output appear here.")
            } actions: {
                Button("Build Game…", systemImage: "hammer", action: showBuild).buttonStyle(.glassProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(build.gameName.isEmpty ? "Build" : build.gameName).font(.title2.weight(.semibold))
                    Spacer()
                    Text(build.state.capitalized).foregroundStyle(.secondary)
                }
                Text("\(build.systemName) · \(build.engineName)").foregroundStyle(.secondary)
                if running {
                    if let fraction = build.fraction { ProgressView(value: fraction) } else { ProgressView() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(build.stage).font(.headline)
                    Text(build.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Compiler Output").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                BuildLogView(text: build.log.isEmpty ? "Waiting for compiler output." : build.log)
                    .frame(minHeight: 150, maxHeight: .infinity)
                HStack {
                    Button("Show Build Files", systemImage: "folder") { build.reveal() }
                    Spacer()
                    if running {
                        Button("Stop Build", systemImage: "stop.fill", role: .destructive) { build.stop() }
                            .disabled(build.state == "cancelling")
                    } else {
                        Button("New Build…", systemImage: "hammer", action: showBuild).buttonStyle(.glass)
                    }
                }
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct LibrarySettings: View {
    @AppStorage("library.grid") private var grid = false
    @AppStorage("library.inspector") private var inspector = true
    @AppStorage("library.metadata") private var metadata = true
    @AppStorage("library.theme") private var theme = "System"
    @AppStorage("builder.switch2mac") private var engineFolder = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Library") {
                Picker("Appearance", selection: $theme) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0).tag($0) } }
                Toggle("Use Grid View", isOn: $grid)
                Toggle("Show Game Inspector", isOn: $inspector)
                Toggle("Show Title IDs", isOn: $metadata)
            }
            Section("Build Engine") {
                Text(project.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Choose Switch2Mac Folder…") { chooseEngine() }
                    if !engineFolder.isEmpty { Button("Use Default") { engineFolder = "" } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 330)
        .preferredColorScheme(theme == "Dark" ? .dark : (theme == "Light" ? .light : nil))
        .alert("Invalid Engine Folder", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func chooseEngine() {
        let panel = NSOpenPanel()
        panel.title = "Choose Switch2Mac Folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isReadableFile(atPath: url.appendingPathComponent("switch2mac.py").path) else {
            error = "The folder must contain switch2mac.py."
            return
        }
        engineFolder = url.path
    }
}

@MainActor final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

@main
struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherDelegate.self) private var appDelegate
    @StateObject private var builder = BuildManager()
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup("Switch2Mac", id: "native-library") { LibraryView(library: library, build: builder) }
            .defaultSize(width: 1140, height: 660)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Add Game App…") { library.add() }.keyboardShortcut("o")
                }
                CommandMenu("Build") {
                    Button("Build Game…") { NotificationCenter.default.post(name: .switchMacBuildRequested, object: nil) }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    Button("Stop Build") { builder.stop() }.disabled(!["running", "starting"].contains(builder.state))
                }
                CommandMenu("Library") {
                    Button("Refresh Library") { library.load() }.keyboardShortcut("r")
                }
            }
        Settings { LibrarySettings() }
    }
}

extension Notification.Name {
    static let switchMacBuildRequested = Notification.Name("switchMacBuildRequested")
}
