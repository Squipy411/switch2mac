import AppKit
import GameController
import SwiftUI

enum GameSettingsPage: String, CaseIterable, Identifiable {
    case graphics = "Graphics"
    case controllers = "Controllers"
    case saves = "Saves"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .graphics: "display"
        case .controllers: "gamecontroller"
        case .saves: "externaldrive"
        }
    }
}

struct GameSetting: Decodable, Identifiable {
    let env: String
    let kind: String
    let section: String
    let label: String
    let note: String?
    let initial: String
    var options: [[String]]?
    var on: String?
    var off: String?
    var min: Double?
    var max: Double?
    var step: Double?
    var needs: String?

    var id: String { env }

    enum CodingKeys: String, CodingKey {
        case env, kind, section, label, note, options, on, off, min, max, step, needs
        case initial = "default"
    }

    func accepts(_ value: String) -> Bool {
        switch kind {
        case "choice": options?.contains { $0.count == 2 && $0[0] == value } == true
        case "toggle": [on ?? "1", off ?? "0"].contains(value)
        case "range": Double(value).map { $0.isFinite && $0 >= (min ?? 0) && $0 <= (max ?? 1) } == true
        default: false
        }
    }
}

struct GamePreferences {
    private struct SettingsFile: Decodable { let settings: [GameSetting] }
    private static let supported = Set([
        "DM_FULLSCREEN", "DM_OPMODE", "DM_LANG", "DM_UPSCALER", "DM_PRESENT_UPSCALE",
        "DM_METAL_HUD", "DM_PRESENT_SNAP", "DM_PSO_MTL4", "DM_PSO_PREBUILD",
        "DM_NVN_ENC_THREAD", "DM_RT", "DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_RUMBLE_MIN"
    ])
    let game: Game

    init(_ game: Game) { self.game = game }

    var rows: [GameSetting] {
        guard game.titleID != nil,
              let resource = game.bundle?.resources.appendingPathComponent("dm/launcher.json"),
              let data = try? Data(contentsOf: resource),
              let settings = try? JSONDecoder().decode(SettingsFile.self, from: data) else { return [] }
        return settings.settings.filter { Self.supported.contains($0.env) && $0.accepts($0.initial) }
    }

    var values: [String: String] {
        guard let url = game.settingsURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    var launchEnvironment: [String: String] {
        guard game.titleID != nil else { return [:] }
        let stored = values
        var environment: [String: String] = [:]
        for row in rows {
            if let value = stored[row.env], row.accepts(value) { environment[row.env] = value }
        }
        if stored["DM_PAD_MERGE"] == "1" { environment["DM_PAD_MERGE"] = "1" }
        if stored["DM_KBD_PLAYER"] == "own" { environment["DM_KBD_PLAYER"] = "own" }
        return environment
    }

    func update(_ updates: [String: String?]) throws {
        guard let url = game.settingsURL else { return }
        var current = values
        for (key, value) in updates { current[key] = value }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(current).write(to: url, options: .atomic)
    }
}

private enum ControllerAssignment: String, CaseIterable, Identifiable {
    case automatic = "By connection order"
    case merged = "All controllers play as Player 1"
    case keyboard = "Keyboard is Player 1"
    var id: Self { self }
    var explanation: String {
        switch self {
        case .automatic: "The first connected controller shares Player 1 with the keyboard. Additional controllers get their own slots."
        case .merged: "Every connected controller shares Player 1."
        case .keyboard: "The keyboard holds Player 1. Controllers are assigned from Player 2."
        }
    }
}

struct GameSettingsView: View {
    let game: Game
    @ObservedObject var library: Library
    @State var page: GameSettingsPage
    @State private var values: [String: String] = [:]
    @State private var rows: [GameSetting] = []
    @State private var controllers: [String] = []
    @State private var controllerModels: [String] = []
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    private var preferences: GamePreferences { GamePreferences(game) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(nsImage: library.icon(game)).resizable().scaledToFit().frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title).font(.title2.weight(.semibold))
                    Text(game.bundle?.isPortable == true ? "Shared game settings" : "Settings for Play from Switch2Mac")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 25).padding(.vertical, 19)

            Picker("Game settings section", selection: $page) {
                ForEach(GameSettingsPage.allCases) { section in Text(section.rawValue).tag(section) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 355)
            .padding(.bottom, 13)

            Group {
                switch page {
                case .graphics: graphics
                case .controllers: controllerPane
                case .saves: savePane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text(feedback ?? "Changes apply when you start the game again.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 570, height: 590)
        .onAppear {
            values = preferences.values
            rows = preferences.rows
            updateControllers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in updateControllers() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in updateControllers() }
        .alert("Couldn’t Save Settings", isPresented: Binding(get: { feedback != nil }, set: { if !$0 { feedback = nil } })) {
            Button("OK") { feedback = nil }
        } message: { Text(feedback ?? "") }
    }

    private var graphics: some View {
        Form {
            if game.bundle?.hasPackagedPerformance == true {
                Section("Profile") {
                    Toggle("Use the bundled performance profile", isOn: Binding(
                        get: { values["SWITCH2MAC_PERFORMANCE"] != "0" },
                        set: { update(["SWITCH2MAC_PERFORMANCE": $0 ? "1" : "0"]) }
                    ))
                    Text("This profile may lower the 3D scene resolution. The game interface stays at its own resolution.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if rows.filter({ $0.section != "Controls" }).isEmpty {
                Section {
                    Text("This game build doesn’t provide configurable graphics settings.")
                        .foregroundStyle(.secondary)
                }
            } else {
                let display = rows.filter { $0.section != "Controls" && $0.section != "Performance" }
                if !display.isEmpty {
                    Section("Display") { ForEach(display) { setting($0) } }
                }
                let performance = rows.filter { $0.section == "Performance" }
                if !performance.isEmpty {
                    Section("Performance") { ForEach(performance) { setting($0) } }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var controllerPane: some View {
        Form {
            Section("Player Assignment") {
                Picker("Assign players", selection: Binding(
                    get: {
                        if values["DM_PAD_MERGE"] == "1" { return .merged }
                        if values["DM_KBD_PLAYER"] == "own" { return .keyboard }
                        return .automatic
                    },
                    set: { (selection: ControllerAssignment) in
                        update([
                            "DM_PAD_MERGE": selection == .merged ? "1" : nil,
                            "DM_KBD_PLAYER": selection == .keyboard ? "own" : nil
                        ])
                    }
                )) {
                    ForEach(ControllerAssignment.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(game.titleID == nil)
                Text(assignment.explanation).font(.footnote).foregroundStyle(.secondary)
                if game.bundle?.supportsPreferredController == true {
                    Picker("Preferred Player 1 controller", selection: Binding(
                        get: { values["DM_PAD_PLAYER1"] ?? "" },
                        set: { update(["DM_PAD_PLAYER1": $0.isEmpty ? nil : $0]) }
                    )) {
                        Text("Automatic").tag("")
                        ForEach(controllerChoices, id: \.self) { name in
                            Text(controllerModels.contains(name) ? name : name + " (disconnected)").tag(name)
                        }
                    }
                    .disabled(assignment != .automatic)
                    Text("The game checks this preference at launch. Controllers with the same model name share the preference.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Connected Controllers") {
                if controllers.isEmpty {
                    Text("No controllers detected by macOS.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(controllers.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "gamecontroller")
                    }
                }
                Text("Connect a controller in System Settings. The game assigns its player slots when it opens.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            let controls = rows.filter { $0.section == "Controls" }
            if !controls.isEmpty {
                Section("Rumble") { ForEach(controls) { setting($0) } }
            }
        }
        .formStyle(.grouped)
    }

    private var savePane: some View {
        Form {
            Section("Local Saves") {
                if let root = game.saveRoot {
                    LabeledContent("Title ID", value: game.titleID ?? "—")
                    Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("This Mac keeps one set of saves for this title. The standalone game and Switch2Mac use this same folder.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("Show Save Folder", systemImage: "folder") { library.revealSaves(game) }
                        Button("Back Up…", systemImage: "arrow.down.document") { library.backupSaves(game) }
                    }
                    .disabled(library.busy.contains(game.id))
                } else {
                    Text("The game’s save location isn’t declared in this app bundle.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var assignment: ControllerAssignment {
        if values["DM_PAD_MERGE"] == "1" { return .merged }
        if values["DM_KBD_PLAYER"] == "own" { return .keyboard }
        return .automatic
    }

    private var controllerChoices: [String] {
        let saved = values["DM_PAD_PLAYER1"].map { [$0] } ?? []
        return Set(controllerModels + saved).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func updateControllers() {
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }
        controllers = connected.map { $0.vendorName ?? "Game Controller" }
        controllerModels = connected.compactMap(\.vendorName).filter {
            $0.utf8.count <= 63 && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }

    private func update(_ changes: [String: String?]) {
        do { try preferences.update(changes); values = preferences.values }
        catch { feedback = error.localizedDescription }
    }

    private func defaultValue(_ row: GameSetting) -> String {
        if game.bundle?.hasPackagedPerformance == true, values["SWITCH2MAC_PERFORMANCE"] != "0" {
            let defaults = game.bundle?.performanceProfile?["defaults"] as? [String: String]
            if let value = defaults?[row.env], row.accepts(value) { return value }
        }
        return row.initial
    }

    private func current(_ row: GameSetting) -> String {
        values[row.env].flatMap { row.accepts($0) ? $0 : nil } ?? defaultValue(row)
    }

    @ViewBuilder private func setting(_ row: GameSetting) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            switch row.kind {
            case "choice":
                Picker(row.label, selection: Binding(get: { current(row) }, set: { update([row.env: $0]) })) {
                    ForEach((row.options ?? []).filter { $0.count == 2 }, id: \.self) { Text($0[1]).tag($0[0]) }
                }
            case "toggle":
                Toggle(row.label, isOn: Binding(
                    get: { current(row) == (row.on ?? "1") },
                    set: { update([row.env: $0 ? (row.on ?? "1") : (row.off ?? "0")]) }
                ))
            case "range":
                if let minimum = row.min, let maximum = row.max, let step = row.step, minimum < maximum, step > 0 {
                    let initial = Double(current(row)) ?? minimum
                    LabeledContent(row.label) {
                        HStack(spacing: 9) {
                            Slider(value: Binding(get: { initial }, set: { update([row.env: String($0)]) }), in: minimum...maximum, step: step)
                                .accessibilityLabel(row.label)
                                .frame(minWidth: 75, idealWidth: 125, maxWidth: 150)
                            Text(initial, format: .number.precision(.fractionLength(0...2))).monospacedDigit().frame(width: 35)
                        }
                    }
                }
            default: EmptyView()
            }
            if let note = row.note, !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        .disabled(!requirementMet(row))
        .contextMenu {
            Button("Reset to App Default") { update([row.env: nil]) }
                .disabled(values[row.env] == nil)
        }
    }

    private func requirementMet(_ row: GameSetting) -> Bool {
        guard let rule = row.needs?.split(separator: "=", maxSplits: 1), rule.count == 2,
              let dependency = rows.first(where: { $0.env == rule[0] }) else { return true }
        return current(dependency) == rule[1]
    }
}
