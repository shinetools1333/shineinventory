import SwiftUI
import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

// MARK: - App Entry

@main
struct ShineComputerInventoryApp: App {
    @StateObject private var store: InventoryStore
    @StateObject private var agent: InventoryAgentController
    @StateObject private var adminWindowController = AdminWindowController()
    @StateObject private var preferencesWindowController = PreferencesWindowController()
    @StateObject private var updater = AppUpdaterController()

    init() {
        let inventoryStore = InventoryStore()
        let inventoryAgent = InventoryAgentController(store: inventoryStore)

        _store = StateObject(wrappedValue: inventoryStore)
        _agent = StateObject(wrappedValue: inventoryAgent)

        // Start the helper as soon as the app launches, not only after the
        // menu is opened. This lets the agent attempt its auto-mount right away.
        inventoryAgent.start()
    }

    var body: some Scene {
        MenuBarExtra {
            AgentMenuView()
                .environmentObject(store)
                .environmentObject(agent)
                .environmentObject(adminWindowController)
                .environmentObject(preferencesWindowController)
                .environmentObject(updater)
                .onAppear {
                    DispatchQueue.main.async {
                        agent.start()
                        agent.refreshPresenceStatus(writeHeartbeat: true)
                    }
                }
        } label: {
            AgentMenuBarLabel(state: agent.state, connectedCount: agent.visibleConnectedAgents.count)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView(agent: agent, updater: updater)
                .preferredColorScheme(.dark)
                .frame(width: 620, height: 650)
        }
    }
}

@MainActor
final class AdminWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var adminWindow: NSWindow?
    private weak var store: InventoryStore?

    func requestAdminUnlock(store: InventoryStore, agent: InventoryAgentController, bypassPassword: Bool = false) {
        if bypassPassword {
            open(store: store, agent: agent)
            return
        }

        // This is usually launched from a MenuBarExtra menu. Delaying the alert
        // slightly lets the menu close first, which prevents the password field
        // from appearing but not accepting keyboard input.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }

            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Open Full App"
            alert.informativeText = "Enter the admin password to open full control."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")

            let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            passwordField.placeholderString = "Password"
            alert.accessoryView = passwordField
            alert.layout()
            alert.window.initialFirstResponder = passwordField
            alert.window.makeKeyAndOrderFront(nil)
            passwordField.becomeFirstResponder()

            let response = alert.runModal()

            guard response == .alertFirstButtonReturn else { return }

            if passwordField.stringValue == LocalPreferences.adminPassword {
                self.open(store: store, agent: agent)
            } else {
                let wrongPasswordAlert = NSAlert()
                wrongPasswordAlert.messageText = "Incorrect Password"
                wrongPasswordAlert.informativeText = "The full app was not opened."
                wrongPasswordAlert.alertStyle = .warning
                wrongPasswordAlert.addButton(withTitle: "OK")
                wrongPasswordAlert.runModal()
            }
        }
    }

    func open(store: InventoryStore, agent: InventoryAgentController) {
        self.store = store
        store.refreshFromSharedInventory()

        if let adminWindow {
            adminWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView()
            .environmentObject(store)
            .environmentObject(agent)
            .preferredColorScheme(.dark)
            .frame(minWidth: 1050, minHeight: 650)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1050, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Shine Computer Inventory"
        window.contentViewController = NSHostingController(rootView: rootView)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        adminWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        store?.save()
    }
}


enum LocalPreferenceKeys {
    static let launchAgentAtLogin = "ShineInventoryPreferences.launchAgentAtLogin"
    static let openAsAgentByDefault = "ShineInventoryPreferences.openAsAgentByDefault"
    static let autoMountServer = "ShineInventoryPreferences.autoMountServer"
    static let heartbeatIntervalSeconds = "ShineInventoryPreferences.heartbeatIntervalSeconds"
    static let connectedTimeoutSeconds = "ShineInventoryPreferences.connectedTimeoutSeconds"
    static let inventorySyncIntervalDays = "ShineInventoryPreferences.inventorySyncIntervalDays"
    static let adminPassword = "ShineInventoryPreferences.adminPassword"
    static let updateFeedURL = "ShineInventoryPreferences.updateFeedURL"
}

enum LocalPreferences {
    static var launchAgentAtLogin: Bool {
        UserDefaults.standard.object(forKey: LocalPreferenceKeys.launchAgentAtLogin) as? Bool ?? true
    }

    static var openAsAgentByDefault: Bool {
        UserDefaults.standard.object(forKey: LocalPreferenceKeys.openAsAgentByDefault) as? Bool ?? true
    }

    static var autoMountServer: Bool {
        UserDefaults.standard.object(forKey: LocalPreferenceKeys.autoMountServer) as? Bool ?? true
    }

    static var heartbeatIntervalSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: LocalPreferenceKeys.heartbeatIntervalSeconds)
        return value > 0 ? value : 15
    }

    static var connectedTimeoutSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: LocalPreferenceKeys.connectedTimeoutSeconds)
        return value > 0 ? value : 60
    }

    static var inventorySyncIntervalDays: TimeInterval {
        let value = UserDefaults.standard.double(forKey: LocalPreferenceKeys.inventorySyncIntervalDays)
        return value > 0 ? value : 7
    }

    static var adminPassword: String {
        let saved = UserDefaults.standard.string(forKey: LocalPreferenceKeys.adminPassword) ?? ""
        return saved.isEmpty ? "Shine7575" : saved
    }

    static var updateFeedURL: String {
        let saved = UserDefaults.standard.string(forKey: LocalPreferenceKeys.updateFeedURL) ?? ""
        return saved.isEmpty ? AppUpdaterController.defaultFeedURLString : saved
    }
}

@MainActor
final class PreferencesWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var preferencesWindow: NSWindow?

    func open(agent: InventoryAgentController, updater: AppUpdaterController) {
        if let preferencesWindow {
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = PreferencesView(agent: agent, updater: updater)
            .preferredColorScheme(.dark)
            .frame(width: 620, height: 650)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Shine Computer Inventory Settings"
        window.contentViewController = NSHostingController(rootView: rootView)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        preferencesWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        preferencesWindow = nil
    }
}


// MARK: - App Updater

struct AppUpdateInfo: Codable, Equatable {
    var version: String
    var build: Int?
    var downloadURL: String
    var notes: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case latest
        case build
        case downloadURL
        case downloadUrl
        case installerURL
        case installerUrl
        case appZipURL
        case appZipUrl
        case notes
        case releaseNotes
        case changelog
    }

    init(version: String, build: Int? = nil, downloadURL: String, notes: [String] = []) {
        self.version = version
        self.build = build
        self.downloadURL = downloadURL
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
            ?? container.decodeIfPresent(String.self, forKey: .latest)
            ?? ""
        build = try container.decodeIfPresent(Int.self, forKey: .build)
        downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
            ?? container.decodeIfPresent(String.self, forKey: .downloadUrl)
            ?? container.decodeIfPresent(String.self, forKey: .installerURL)
            ?? container.decodeIfPresent(String.self, forKey: .installerUrl)
            ?? container.decodeIfPresent(String.self, forKey: .appZipURL)
            ?? container.decodeIfPresent(String.self, forKey: .appZipUrl)
            ?? ""
        if let noteList = try container.decodeIfPresent([String].self, forKey: .notes) {
            notes = noteList
        } else if let noteList = try container.decodeIfPresent([String].self, forKey: .releaseNotes) {
            notes = noteList
        } else if let changelogText = try container.decodeIfPresent(String.self, forKey: .changelog) {
            notes = changelogText.split(separator: "\n").map { String($0) }
        } else {
            notes = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(build, forKey: .build)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encode(notes, forKey: .notes)
    }
}

@MainActor
final class AppUpdaterController: ObservableObject {
    static let currentVersion = "1.0"
    static let defaultFeedURLString = "https://raw.githubusercontent.com/ShineTools1333/ShineComputerInventory/main/versions.json"

    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var statusMessage = ""
    @Published var availableUpdate: AppUpdateInfo?

    func checkForUpdates(showNoUpdateAlert: Bool = true) {
        let feed = LocalPreferences.updateFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: feed), !feed.isEmpty else {
            statusMessage = "Update feed URL is missing."
            showAlert(title: "Update Feed Missing", message: "Enter a valid update feed URL in Settings.")
            return
        }

        isChecking = true
        statusMessage = "Checking for updates…"

        URLSession.shared.dataTask(with: url) { data, _, error in
            Task { @MainActor in
                self.isChecking = false

                if let error {
                    self.statusMessage = "Could not check for updates."
                    self.showAlert(title: "Update Check Failed", message: error.localizedDescription)
                    return
                }

                guard let data else {
                    self.statusMessage = "No update data received."
                    self.showAlert(title: "Update Check Failed", message: "No update data was received from the feed.")
                    return
                }

                do {
                    let update = try JSONDecoder().decode(AppUpdateInfo.self, from: data)
                    guard !update.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !update.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.statusMessage = "Update feed is missing version or download URL."
                        self.showAlert(title: "Invalid Update Feed", message: "The update feed must include a version and downloadURL.")
                        return
                    }

                    if self.isNewer(update.version, than: Self.currentVersion) {
                        self.availableUpdate = update
                        self.statusMessage = "Update available: v\(update.version)"
                        self.showUpdateAvailableAlert(update)
                    } else {
                        self.availableUpdate = nil
                        self.statusMessage = "You are up to date."
                        if showNoUpdateAlert {
                            self.showAlert(title: "Shine Computer Inventory is Up to Date", message: "Current version: v\(Self.currentVersion)")
                        }
                    }
                } catch {
                    self.statusMessage = "Could not read update feed."
                    self.showAlert(title: "Update Check Failed", message: error.localizedDescription)
                }
            }
        }.resume()
    }

    func installAvailableUpdate() {
        guard let update = availableUpdate else {
            checkForUpdates()
            return
        }
        downloadAndOpen(update)
    }

    private func showUpdateAvailableAlert(_ update: AppUpdateInfo) {
        let notes = update.notes.prefix(6).map { "• \($0)" }.joined(separator: "\n")
        let message = notes.isEmpty
            ? "Version \(update.version) is available."
            : "Version \(update.version) is available.\n\n\(notes)"

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            downloadAndOpen(update)
        }
    }

    private func downloadAndOpen(_ update: AppUpdateInfo) {
        guard let url = URL(string: update.downloadURL) else {
            showAlert(title: "Invalid Download URL", message: update.downloadURL)
            return
        }

        isDownloading = true
        statusMessage = "Downloading update…"

        URLSession.shared.downloadTask(with: url) { temporaryURL, response, error in
            Task { @MainActor in
                self.isDownloading = false

                if let error {
                    self.statusMessage = "Download failed."
                    self.showAlert(title: "Download Failed", message: error.localizedDescription)
                    return
                }

                guard let temporaryURL else {
                    self.statusMessage = "Download failed."
                    self.showAlert(title: "Download Failed", message: "No downloaded file was received.")
                    return
                }

                let suggestedName = response?.suggestedFilename ?? url.lastPathComponent
                let safeName = suggestedName.isEmpty ? "ShineComputerInventory_v\(update.version).zip" : suggestedName
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
                let destinationURL = downloadsURL.appendingPathComponent(safeName)

                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
                    self.statusMessage = "Update downloaded."
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                    NSWorkspace.shared.open(destinationURL)
                } catch {
                    self.statusMessage = "Could not save update."
                    self.showAlert(title: "Install Update Failed", message: error.localizedDescription)
                }
            }
        }.resume()
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = versionParts(candidate)
        let rhs = versionParts(current)
        let count = max(lhs.count, rhs.count)

        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left > right { return true }
            if left < right { return false }
        }
        return false
    }

    private func versionParts(_ version: String) -> [Int] {
        version
            .replacingOccurrences(of: "v", with: "", options: .caseInsensitive)
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct PreferencesView: View {
    @ObservedObject var agent: InventoryAgentController
    @ObservedObject var updater: AppUpdaterController
    @AppStorage(LocalPreferenceKeys.launchAgentAtLogin) private var launchAgentAtLogin = true
    @AppStorage(LocalPreferenceKeys.openAsAgentByDefault) private var openAsAgentByDefault = true
    @AppStorage(LocalPreferenceKeys.autoMountServer) private var autoMountServer = true
    @AppStorage(LocalPreferenceKeys.heartbeatIntervalSeconds) private var heartbeatIntervalSeconds = 15.0
    @AppStorage(LocalPreferenceKeys.connectedTimeoutSeconds) private var connectedTimeoutSeconds = 60.0
    @AppStorage(LocalPreferenceKeys.inventorySyncIntervalDays) private var inventorySyncIntervalDays = 7.0
    @AppStorage(LocalPreferenceKeys.adminPassword) private var storedAdminPassword = ""
    @AppStorage(LocalPreferenceKeys.updateFeedURL) private var updateFeedURL = AppUpdaterController.defaultFeedURLString
    @State private var newAdminPassword = ""
    @State private var confirmAdminPassword = ""
    @State private var passwordStatus = ""

    private let heartbeatOptions: [Double] = [15, 30, 60, 120]
    private let timeoutOptions: [Double] = [60, 120, 300]
    private let syncOptions: [Double] = [1, 3, 7, 14, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(ShineStyle.yellow)

            Form {
                Section("General") {
                    Toggle("Launch Agent at Login", isOn: $launchAgentAtLogin)
                    Toggle("Open as Agent by Default", isOn: $openAsAgentByDefault)
                    Text("These are local settings for this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Network") {
                    LabeledContent("Server") {
                        Text("smb://10.1.10.242/SHINE-INTERNAL_1")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Mounted Path") {
                        Text("/Volumes/SHINE-INTERNAL_1")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Toggle("Auto-mount server", isOn: $autoMountServer)
                    LabeledContent("Status") {
                        Text(AgentNetworkStorage.isSharedVolumeMounted ? "Connected" : "Not Connected")
                            .foregroundStyle(AgentNetworkStorage.isSharedVolumeMounted ? ShineStyle.yellow : .secondary)
                    }
                    Button("Check Server Now") {
                        agent.checkServerNow()
                    }
                }

                Section("Sync") {
                    Picker("Inventory Sync", selection: $inventorySyncIntervalDays) {
                        ForEach(syncOptions, id: \.self) { days in
                            Text(days == 1 ? "Daily" : "Every \(Int(days)) days").tag(days)
                        }
                    }
                    Picker("Heartbeat", selection: $heartbeatIntervalSeconds) {
                        ForEach(heartbeatOptions, id: \.self) { seconds in
                            Text("Every \(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                    Picker("Connected Timeout", selection: $connectedTimeoutSeconds) {
                        ForEach(timeoutOptions, id: \.self) { seconds in
                            Text("\(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                    Button("Sync Now") {
                        agent.pingNow()
                    }
                    .disabled(!AgentNetworkStorage.isSharedVolumeMounted || agent.state == .updating)
                }

                Section("Updates") {
                    LabeledContent("Current Version") {
                        Text(AppUpdaterController.currentVersion)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Update Feed URL", text: $updateFeedURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(updater.isChecking ? "Checking…" : "Check for Updates") {
                            updater.checkForUpdates()
                        }
                        .disabled(updater.isChecking || updateFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Text(updater.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let update = updater.availableUpdate {
                        Text("Available: v\(update.version)")
                            .font(.caption)
                            .foregroundStyle(ShineStyle.yellow)
                        Button(updater.isDownloading ? "Downloading…" : "Install Update…") {
                            updater.installAvailableUpdate()
                        }
                        .disabled(updater.isDownloading)
                    }
                }

                Section("Admin") {
                    SecureField("New Admin Password", text: $newAdminPassword)
                    SecureField("Confirm Password", text: $confirmAdminPassword)
                    HStack {
                        Button("Change Admin Password") {
                            saveAdminPassword()
                        }
                        .disabled(newAdminPassword.isEmpty || newAdminPassword != confirmAdminPassword)

                        Text(passwordStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(18)
        .onChange(of: heartbeatIntervalSeconds) { _, _ in agent.applyLocalPreferences() }
        .onChange(of: connectedTimeoutSeconds) { _, _ in agent.applyLocalPreferences() }
        .onChange(of: inventorySyncIntervalDays) { _, _ in agent.applyLocalPreferences() }
        .onChange(of: autoMountServer) { _, _ in agent.applyLocalPreferences() }
    }

    private func saveAdminPassword() {
        guard !newAdminPassword.isEmpty, newAdminPassword == confirmAdminPassword else {
            passwordStatus = "Passwords do not match."
            return
        }

        storedAdminPassword = newAdminPassword
        newAdminPassword = ""
        confirmAdminPassword = ""
        passwordStatus = "Admin password updated for this Mac."
    }
}


// MARK: - Agent / Helper Mode

enum AgentConnectionState: String, CaseIterable {
    case unknown
    case connected
    case waitingForServer
    case updating
    case updated
    case failed

    var displayName: String {
        switch self {
        case .unknown: return "Checking…"
        case .connected: return "Connected"
        case .waitingForServer: return "Waiting for SHINE-INTERNAL_1"
        case .updating: return "Updating inventory…"
        case .updated: return "Updated"
        case .failed: return "Update failed"
        }
    }
}

struct AgentPingResult {
    var success: Bool
    var message: String
    var updatedRecordName: String?
}

struct AgentPresence: Identifiable, Codable, Equatable {
    var id: String
    var machineName: String
    var macUsername: String
    var serialNumber: String
    var ipAddress: String
    var lastSeen: Date

    var displayName: String {
        machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : machineName
    }

    var lastSeenText: String {
        DateFormatter.inventoryDateTime.string(from: lastSeen)
    }
}

final class InventoryAgentController: ObservableObject {
    @Published var state: AgentConnectionState = .unknown
    @Published var statusMessage = "Checking SHINE-INTERNAL_1…"
    @Published var lastSuccessfulPing: Date?
    @Published var lastAttempt: Date?
    @Published var connectedAgents: [AgentPresence] = []

    var visibleConnectedAgents: [AgentPresence] {
        connectedAgents
    }

    var visibleConnectedAgentCount: Int {
        connectedAgents.count
    }

    private let store: InventoryStore
    private var weeklyTimer: Timer?
    private var statusTimer: Timer?
    private var presenceTimer: Timer?
    private var hasStarted = false
    private var isMounting = false
    private var isRefreshingPresence = false
    private var hasRunStartupConnectionSync = false
    private let lastPingDefaultsKey = "ShineInventoryAgent.lastSuccessfulPing"
    private var lastAppliedHeartbeatInterval: TimeInterval = 0

    private var weeklyInterval: TimeInterval {
        LocalPreferences.inventorySyncIntervalDays * 24 * 60 * 60
    }

    init(store: InventoryStore) {
        self.store = store
        if let savedDate = UserDefaults.standard.object(forKey: lastPingDefaultsKey) as? Date {
            lastSuccessfulPing = savedDate
        }
        refreshConnectionStatus()
    }

    var statusBadgeSystemName: String? {
        switch state {
        case .connected, .updated:
            return "checkmark.circle.fill"
        case .updating:
            return "arrow.triangle.2.circlepath"
        case .waitingForServer:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .unknown:
            return nil
        }
    }

    var lastSuccessfulPingText: String {
        guard let lastSuccessfulPing else { return "Never" }
        return DateFormatter.inventoryDateTime.string(from: lastSuccessfulPing)
    }

    func start() {
        guard !hasStarted else {
            refreshConnectionStatus()
            return
        }

        hasStarted = true

        // On launch, immediately try to connect/mount. The previous build only
        // refreshed status at launch, so an unmounted drive stayed unmounted
        // until the weekly sync or a manual menu command.
        if AgentNetworkStorage.isSharedVolumeMounted {
            refreshConnectionStatus()
            runStartupConnectionSyncIfNeeded()
        } else if LocalPreferences.autoMountServer {
            mountServer(shouldPingAfterMount: true)
        } else {
            state = .waitingForServer
            statusMessage = "SHINE-INTERNAL_1 is not mounted. Auto-mount is off."
        }

        if weeklyTimer == nil {
            weeklyTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.runWeeklyPingIfDue()
                }
            }
        }

        // Keep the menu status honest if the drive is disconnected while the
        // agent is still running. This is status-only and does not constantly
        // retry mounting or bother the user.
        if statusTimer == nil {
            statusTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshConnectionStatus()
                }
            }
        }

        setupPresenceTimer()

        // Heartbeat is separate from the weekly inventory sync. This should run
        // even when the full/admin app window is never opened, so other machines
        // can reliably see this helper as connected.
        refreshPresenceStatus(writeHeartbeat: true)
    }

    func refreshConnectionStatus() {
        if AgentNetworkStorage.isSharedVolumeMounted {
            if state != .updating {
                state = .connected
                statusMessage = "SHINE-INTERNAL_1 is connected."
            }
            refreshPresenceStatus(writeHeartbeat: false)
        } else {
            state = .waitingForServer
            statusMessage = "SHINE-INTERNAL_1 is not mounted."
            connectedAgents = []
        }
    }

    func refreshPresenceStatus(writeHeartbeat: Bool) {
        guard AgentNetworkStorage.isSharedVolumeMounted else {
            DispatchQueue.main.async {
                self.connectedAgents = []
            }
            return
        }

        // Presence refreshes are intentionally allowed to overlap. They only
        // read/write small heartbeat JSON files, and skipping a refresh here
        // made the menu count occasionally disagree with the menu-bar count.
        DispatchQueue.global(qos: .utility).async {
            if writeHeartbeat {
                AgentNetworkStorage.writeCurrentAgentPresence()
            }

            let agents = AgentNetworkStorage.readConnectedAgentPresences()

            DispatchQueue.main.async {
                self.connectedAgents = agents
            }
        }
    }

    func applyLocalPreferences() {
        setupPresenceTimer()

        if LocalPreferences.autoMountServer {
            if !AgentNetworkStorage.isSharedVolumeMounted {
                mountServer(shouldPingAfterMount: false)
            }
        } else if !AgentNetworkStorage.isSharedVolumeMounted {
            state = .waitingForServer
            statusMessage = "SHINE-INTERNAL_1 is not mounted. Auto-mount is off."
        }

        refreshPresenceStatus(writeHeartbeat: AgentNetworkStorage.isSharedVolumeMounted)
    }

    private func setupPresenceTimer() {
        let interval = LocalPreferences.heartbeatIntervalSeconds
        guard presenceTimer == nil || interval != lastAppliedHeartbeatInterval else { return }

        presenceTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshPresenceStatus(writeHeartbeat: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
        lastAppliedHeartbeatInterval = interval
    }

    private func runStartupConnectionSyncIfNeeded() {
        guard !hasRunStartupConnectionSync else { return }
        guard AgentNetworkStorage.isSharedVolumeMounted else { return }

        hasRunStartupConnectionSync = true
        pingNow()
    }

    func checkServerNow() {
        lastAttempt = Date()

        if AgentNetworkStorage.isSharedVolumeMounted {
            state = .connected
            statusMessage = "SHINE-INTERNAL_1 is already connected. Checked at \(DateFormatter.agentStatusTime.string(from: Date()))."
            refreshPresenceStatus(writeHeartbeat: true)
            runStartupConnectionSyncIfNeeded()
            return
        }

        mountServer()
    }

    func mountServer(shouldPingAfterMount: Bool = false) {
        guard !isMounting else {
            statusMessage = "Already trying to mount SHINE-INTERNAL_1…"
            return
        }

        isMounting = true
        lastAttempt = Date()
        state = .updating
        statusMessage = "Trying to mount SHINE-INTERNAL_1…"

        DispatchQueue.global(qos: .utility).async {
            let mounted = AgentNetworkStorage.ensureSharedVolumeMounted()

            DispatchQueue.main.async {
                self.isMounting = false

                if mounted {
                    self.state = .connected
                    self.statusMessage = "SHINE-INTERNAL_1 is connected. Checked at \(DateFormatter.agentStatusTime.string(from: Date()))."
                    self.refreshPresenceStatus(writeHeartbeat: true)

                    if shouldPingAfterMount {
                        self.runStartupConnectionSyncIfNeeded()
                    }
                } else {
                    self.state = .waitingForServer
                    self.statusMessage = "Could not mount SHINE-INTERNAL_1. Check network/server access."
                }
            }
        }
    }

    func pingNow() {
        state = .updating
        statusMessage = "Scanning this Mac and updating inventory…"
        lastAttempt = Date()

        // Keep InventoryStore mutations on the main thread. The previous build updated
        // @Published store properties from a background queue, which could crash as soon
        // as the menu opened and the mounted drive made the agent start a ping.
        DispatchQueue.main.async {
            let result = self.store.performAgentPing()

            if result.success {
                let now = Date()
                self.lastSuccessfulPing = now
                UserDefaults.standard.set(now, forKey: self.lastPingDefaultsKey)
                self.state = .updated
                self.statusMessage = result.message
                self.refreshPresenceStatus(writeHeartbeat: true)
            } else {
                self.state = AgentNetworkStorage.isSharedVolumeMounted ? .failed : .waitingForServer
                self.statusMessage = result.message
            }
        }
    }

    private func runWeeklyPingIfDue() {
        guard AgentNetworkStorage.isSharedVolumeMounted else {
            if LocalPreferences.autoMountServer {
                mountServer(shouldPingAfterMount: true)
            } else {
                state = .waitingForServer
                statusMessage = "SHINE-INTERNAL_1 is not mounted. Auto-mount is off."
            }
            return
        }

        let now = Date()
        guard let lastSuccessfulPing else {
            pingNow()
            return
        }

        if now.timeIntervalSince(lastSuccessfulPing) >= weeklyInterval {
            pingNow()
        } else {
            refreshConnectionStatus()
        }
    }
}

enum InventoryFileLockError: LocalizedError {
    case sharedVolumeUnavailable
    case timedOut(lockPath: String)
    case couldNotCreateLock(String)

    var errorDescription: String? {
        switch self {
        case .sharedVolumeUnavailable:
            return "SHINE-INTERNAL_1 is not mounted."
        case .timedOut(let lockPath):
            return "Timed out waiting for another machine to finish writing the inventory JSON. Lock: \(lockPath)"
        case .couldNotCreateLock(let message):
            return "Could not create inventory write lock: \(message)"
        }
    }
}

enum AgentNetworkStorage {
    static let volumeName = "SHINE-INTERNAL_1"
    static let nasIPAddress = "10.1.10.242"
    static let smbShareName = "SHINE-INTERNAL_1"
    static let smbUsername = "edit1"
    static let smbPassword = "edit1"

    static var sharedVolumeURL: URL {
        URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
    }

    static var sharedStorageFolderURL: URL {
        sharedVolumeURL.appendingPathComponent("ShineComputerInventory", isDirectory: true)
    }

    static var sharedStorageFileURL: URL {
        sharedStorageFolderURL.appendingPathComponent("ShineComputerInventory.json")
    }

    static var sharedLocationOptionsFileURL: URL {
        sharedStorageFolderURL.appendingPathComponent("ShineComputerLocations.json")
    }

    static var sharedAgentStatusFolderURL: URL {
        sharedStorageFolderURL.appendingPathComponent("AgentStatus", isDirectory: true)
    }

    static var isSharedVolumeMounted: Bool {
        isExactSharedVolumeMounted()
    }

    private static func isExactSharedVolumeMounted() -> Bool {
        let mountPoint = sharedVolumeURL.path

        // The most reliable check is the live mount table. A leftover folder at
        // /Volumes/SHINE-INTERNAL_1 should not count as mounted.
        let mountOutput = runShell("/sbin/mount")
        if mountOutput
            .components(separatedBy: .newlines)
            .contains(where: { $0.contains(" on \(mountPoint) (") }) {
            return true
        }

        let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []

        return mountedVolumes.contains { url in
            url.path == mountPoint
        }
    }

    static func ensureSharedVolumeMounted() -> Bool {
        if isSharedVolumeMounted { return true }

        let mountPoint = sharedVolumeURL.path

        // If macOS left behind an empty stale mount folder, remove it so Finder
        // does not remount as SHINE-INTERNAL_1-1. rmdir safely fails if the
        // folder is not empty.
        _ = runShell("""
        if [ -d \(shellQuote(mountPoint)) ] && ! /sbin/mount | /usr/bin/grep -F \(shellQuote(" on \(mountPoint) (")) >/dev/null; then
            /bin/rmdir \(shellQuote(mountPoint)) 2>/dev/null || true
        fi
        /bin/mkdir -p \(shellQuote(mountPoint))
        """)

        let encodedUser = percentEncodeForSMB(smbUsername)
        let encodedPassword = percentEncodeForSMB(smbPassword)
        let encodedShare = percentEncodeForSMB(smbShareName)
        let smbURL = "//\(encodedUser):\(encodedPassword)@\(nasIPAddress)/\(encodedShare)"

        _ = runShell("/sbin/mount_smbfs \(shellQuote(smbURL)) \(shellQuote(mountPoint))")

        if isSharedVolumeMounted { return true }

        let finderURL = "smb://\(encodedUser):\(encodedPassword)@\(nasIPAddress)/\(encodedShare)"
        _ = runShell("/usr/bin/open \(shellQuote(finderURL))")

        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.5)
            if isSharedVolumeMounted { return true }
        }

        return false
    }

    static var currentAgentPresenceID: String {
        let rawMachineName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let machineName = cleanPresenceMachineName(rawMachineName)
        let serial = presenceSerialNumber().trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackID = "\(machineName.isEmpty ? rawMachineName : machineName)-\(NSUserName())"
        return serial.isEmpty ? fallbackID : serial
    }

    static func writeCurrentAgentPresence() {
        guard isSharedVolumeMounted else { return }

        // Keep heartbeat lightweight. Do not run the full MacScanner here; that
        // belongs to weekly/manual sync. Presence should update often and should
        // not depend on the full admin window being open.
        let rawMachineName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let machineName = cleanPresenceMachineName(rawMachineName)
        let serial = presenceSerialNumber().trimmingCharacters(in: .whitespacesAndNewlines)
        let id = currentAgentPresenceID

        let presence = AgentPresence(
            id: id,
            machineName: machineName,
            macUsername: NSUserName(),
            serialNumber: serial,
            ipAddress: presenceIPAddress(),
            lastSeen: Date()
        )

        do {
            try FileManager.default.createDirectory(at: sharedAgentStatusFolderURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(presence)
            let fileURL = sharedAgentStatusFolderURL.appendingPathComponent("\(safeFileName(id)).json")
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Heartbeats should never interrupt the inventory app. The main sync
            // status will report server problems separately.
        }
    }

    static func readConnectedAgentPresences(onlineWithin: TimeInterval = LocalPreferences.connectedTimeoutSeconds) -> [AgentPresence] {
        guard isSharedVolumeMounted else { return [] }

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: sharedAgentStatusFolderURL, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(
                at: sharedAgentStatusFolderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cutoff = Date().addingTimeInterval(-onlineWithin)

            return files
                .filter { $0.pathExtension.lowercased() == "json" }
                .compactMap { fileURL -> AgentPresence? in
                    guard let data = try? Data(contentsOf: fileURL),
                          let presence = try? decoder.decode(AgentPresence.self, from: data),
                          presence.lastSeen >= cutoff else { return nil }
                    return presence
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            return []
        }
    }

    private static func cleanPresenceMachineName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        for marker in ["'s ", "’s "] {
            if let range = name.range(of: marker, options: [.caseInsensitive]) {
                name = String(name[..<range.lowerBound])
                break
            }
        }

        for suffix in [" Mac Studio", " MacBook Air", " MacBook Pro", " iMac", " Mac mini", " Mac Pro"] {
            if let range = name.range(of: suffix, options: [.caseInsensitive, .backwards]) {
                name = String(name[..<range.lowerBound])
                break
            }
        }

        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func presenceSerialNumber() -> String {
        runShell("ioreg -l | awk '/IOPlatformSerialNumber/ { print $4; }' | tr -d '\"'")
    }

    private static func presenceIPAddress() -> String {
        runShell("ipconfig getifaddr en0 || ipconfig getifaddr en1")
    }

    private static func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }

    static var inventoryLockDirectoryURL: URL {
        sharedStorageFolderURL.appendingPathComponent("ShineComputerInventory.lock", isDirectory: true)
    }

    static func withInventoryFileLock<T>(timeout: TimeInterval = 12, staleAfter: TimeInterval = 120, operation: () throws -> T) throws -> T {
        let threadDictionary = Thread.current.threadDictionary
        let reentrantKey = "ShineInventoryFileLockHeld"

        if (threadDictionary[reentrantKey] as? Bool) == true {
            return try operation()
        }

        guard ensureSharedVolumeMounted() else {
            throw InventoryFileLockError.sharedVolumeUnavailable
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sharedStorageFolderURL, withIntermediateDirectories: true)

        let lockURL = inventoryLockDirectoryURL
        let lockPath = lockURL.path
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            do {
                try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)

                let ownerInfo = """
                Host: \(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
                User: \(NSUserName())
                PID: \(ProcessInfo.processInfo.processIdentifier)
                Created: \(ISO8601DateFormatter().string(from: Date()))
                """
                try? ownerInfo.write(
                    to: lockURL.appendingPathComponent("owner.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                threadDictionary[reentrantKey] = true
                defer {
                    threadDictionary.removeObject(forKey: reentrantKey)
                    try? fileManager.removeItem(at: lockURL)
                }

                return try operation()
            } catch {
                if fileManager.fileExists(atPath: lockPath) {
                    if let attributes = try? fileManager.attributesOfItem(atPath: lockPath),
                       let modifiedDate = attributes[.modificationDate] as? Date,
                       abs(modifiedDate.timeIntervalSinceNow) > staleAfter {
                        try? fileManager.removeItem(at: lockURL)
                        continue
                    }

                    if Date() >= deadline {
                        throw InventoryFileLockError.timedOut(lockPath: lockPath)
                    }

                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }

                throw InventoryFileLockError.couldNotCreateLock(error.localizedDescription)
            }
        }
    }

    private static func percentEncodeForSMB(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":/@?&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func runShell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum AgentMenuTemplateIcon {
    static func image(for state: AgentConnectionState) -> NSImage {
        let size = NSSize(width: 28, height: 18)
        let output = NSImage(size: size)

        output.lockFocus()

        let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)?.withSymbolConfiguration(baseConfiguration)

        switch state {
        case .waitingForServer:
            // Disconnected is intentionally not template-only: the dim computer + bright slash is clearer.
            NSColor.white.withAlphaComponent(0.38).set()
            base?.draw(
                in: NSRect(x: 1, y: 1, width: 18, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            drawLargeSlash(color: NSColor.white, lineWidth: 2.8)

        default:
            NSColor.black.set()
            base?.draw(
                in: NSRect(x: 1, y: 1, width: 18, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )

            switch state {
            case .updating:
                drawBadge(systemName: "arrow.triangle.2.circlepath")
            case .failed:
                drawBadge(systemName: "exclamationmark.triangle.fill")
            case .unknown:
                drawBadge(systemName: "questionmark.circle.fill")
            case .connected, .updated, .waitingForServer:
                break
            }
        }

        output.unlockFocus()
        output.isTemplate = state != .waitingForServer
        return output
    }

    private static func drawLargeSlash(color: NSColor = .black, lineWidth: CGFloat = 2.4) {
        color.set()
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 3.5, y: 2.5))
        slash.line(to: NSPoint(x: 18.5, y: 16.0))
        slash.lineWidth = lineWidth
        slash.lineCapStyle = .round
        slash.stroke()
    }

    private static func drawBadge(systemName: String) {
        let overlayConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        if let overlay = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.withSymbolConfiguration(overlayConfiguration) {
            overlay.draw(
                in: NSRect(x: 17, y: 0, width: 10, height: 10),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
    }
}

struct AgentMenuBarLabel: View {
    let state: AgentConnectionState
    let connectedCount: Int

    private var accessibilityStatus: String {
        switch state {
        case .connected, .updated:
            return "connected"
        case .updating:
            return "syncing"
        case .waitingForServer:
            return "not connected"
        case .failed:
            return "sync error"
        case .unknown:
            return "checking"
        }
    }

    private var shouldShowConnectedCount: Bool {
        connectedCount > 0 && (state == .connected || state == .updated || state == .updating)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: AgentMenuTemplateIcon.image(for: state))
                .frame(width: 26, height: 18)

            if shouldShowConnectedCount {
                Text("\(connectedCount)")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .accessibilityLabel(Text("Shine Inventory Agent, \(accessibilityStatus), \(connectedCount) connected computers"))
    }
}

struct AgentStatusIcon: View {
    let state: AgentConnectionState
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: size, weight: .semibold))
            .accessibilityLabel(Text("Shine Inventory Agent"))
    }
}

struct AgentMenuView: View {
    @EnvironmentObject private var store: InventoryStore
    @EnvironmentObject private var agent: InventoryAgentController
    @EnvironmentObject private var adminWindowController: AdminWindowController
    @EnvironmentObject private var preferencesWindowController: PreferencesWindowController
    @EnvironmentObject private var updater: AppUpdaterController

    private var canSyncNow: Bool {
        AgentNetworkStorage.isSharedVolumeMounted && agent.state != .updating
    }

    private var primaryStatusText: String {
        let message = agent.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        switch agent.state {
        case .unknown:
            return "Checking server connection…"
        case .connected, .updated:
            if message.localizedCaseInsensitiveContains("checked") ||
                message.localizedCaseInsensitiveContains("already connected") {
                return "✓ Server connected successfully"
            }
            return "Connected to SHINE-INTERNAL_1"
        case .waitingForServer:
            if message.localizedCaseInsensitiveContains("could not mount") {
                return "Could not connect to SHINE-INTERNAL_1"
            }
            return "Waiting for SHINE-INTERNAL_1"
        case .updating:
            if message.localizedCaseInsensitiveContains("mount") {
                return "Connecting to SHINE-INTERNAL_1…"
            }
            return "Syncing inventory…"
        case .failed:
            return "Sync failed"
        }
    }

    private var secondaryStatusText: String? {
        let message = agent.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        if agent.state == .connected || agent.state == .updated {
            if message.localizedCaseInsensitiveContains("checked at") {
                return message
                    .replacingOccurrences(of: "SHINE-INTERNAL_1 is already connected. ", with: "")
                    .replacingOccurrences(of: "SHINE-INTERNAL_1 is connected. ", with: "")
            }
            return nil
        }

        guard agent.state == .failed else { return nil }
        guard !message.isEmpty, message != primaryStatusText else { return nil }
        return message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shine Inventory Agent v1.0")
                .font(.system(size: 13, weight: .semibold))

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryStatusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryStatusText.hasPrefix("✓") ? Color.green : Color.primary)

                Text("Last sync: \(agent.lastSuccessfulPingText)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if let secondaryStatusText {
                    Text(secondaryStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            Text("Connected Computers: \(agent.visibleConnectedAgentCount)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Divider()

            Button("Sync Now") {
                agent.pingNow()
            }
            .disabled(!canSyncNow)
            .help(canSyncNow ? "Sync this Mac with the shared inventory now." : "Connect to SHINE-INTERNAL_1 before syncing.")

            Button("Mount / Check Server") {
                agent.checkServerNow()
            }

            Button("Settings…") {
                preferencesWindowController.open(agent: agent, updater: updater)
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(updater.isChecking)

            Button("Open Full App…") {
                let modifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let shouldBypassPassword = modifierFlags.contains(.command)
                adminWindowController.requestAdminUnlock(store: store, agent: agent, bypassPassword: shouldBypassPassword)
            }
            .help("Enter the admin password to open full control. Command-click to bypass the password.")

            Divider()

            Button("Quit Agent") {
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.system(size: 13))
    }
}

// MARK: - Data Model

struct ComputerRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()

    var location: String = ""
    var machineName: String = ""
    var machineType: String = ""
    var customMachineType: String = ""
    var ram: String = ""
    var customRAM: String = ""
    var storage: String = ""
    var freeSpace: String = ""
    var macOSVersion: String = ""
    var serialNumber: String = ""
    var ipAddress: String = ""
    var installedOn: String = ""

    var macUsername: String = ""
    var adobeAccount: String = ""
    var detectedAdobeAccount: String = ""
    var adobePassword: String = ""

    var status: String = "Active"
    var notes: String = ""
    var isLocked: Bool = false
    var lastUpdated: Date = Date()

    var displayMachineType: String {
        machineType == "Custom" && !customMachineType.isEmpty ? customMachineType : machineType
    }

    var displayRAM: String {
        ram == "Custom" && !customRAM.isEmpty ? customRAM : ram
    }

    var normalizedAdobeAccount: String {
        adobeAccount.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var adobeAccountShortName: String {
        let trimmed = adobeAccount.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return ""
        }

        if let atIndex = trimmed.firstIndex(of: "@") {
            return String(trimmed[..<atIndex])
        }

        return trimmed
    }

    var normalizedLocation: String {
        var updated = location
            .replacingOccurrences(of: "Shine 1 / Edit", with: "Shine 1_Edit")
            .replacingOccurrences(of: "Shine 2 / Edit", with: "Shine 2_Edit")

        for editNumber in 1...8 {
            updated = updated.replacingOccurrences(
                of: "Shine 1_Edit \(editNumber)",
                with: "Edit \(editNumber)_Shine 1"
            )
        }

        for editNumber in 9...16 {
            updated = updated.replacingOccurrences(
                of: "Shine 2_Edit \(editNumber)",
                with: "Edit \(editNumber)_Shine 2"
            )
        }

        return updated
    }

    var searchableText: String {
        [
            normalizedLocation,
            machineName,
            displayMachineType,
            displayRAM,
            storage,
            freeSpace,
            macOSVersion,
            serialNumber,
            ipAddress,
            installedOn,
            macUsername,
            adobeAccount,
            detectedAdobeAccount,
            adobePassword,
            status,
            notes
        ]
        .joined(separator: " ")
        .lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case location
        case machineName
        case machineType
        case customMachineType
        case ram
        case customRAM
        case storage
        case freeSpace
        case macOSVersion
        case serialNumber
        case ipAddress
        case installedOn
        case dateInstalled
        case macUsername
        case adobeAccount
        case detectedAdobeAccount
        case adobePassword
        case status
        case notes
        case isLocked
        case lastUpdated
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        machineName = try container.decodeIfPresent(String.self, forKey: .machineName) ?? ""
        machineType = try container.decodeIfPresent(String.self, forKey: .machineType) ?? ""
        customMachineType = try container.decodeIfPresent(String.self, forKey: .customMachineType) ?? ""
        ram = try container.decodeIfPresent(String.self, forKey: .ram) ?? ""
        customRAM = try container.decodeIfPresent(String.self, forKey: .customRAM) ?? ""
        storage = try container.decodeIfPresent(String.self, forKey: .storage) ?? ""
        freeSpace = try container.decodeIfPresent(String.self, forKey: .freeSpace) ?? ""
        macOSVersion = try container.decodeIfPresent(String.self, forKey: .macOSVersion) ?? ""
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
        ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress) ?? ""

        installedOn = try container.decodeIfPresent(String.self, forKey: .installedOn)
            ?? container.decodeIfPresent(String.self, forKey: .dateInstalled)
            ?? ""

        macUsername = try container.decodeIfPresent(String.self, forKey: .macUsername) ?? ""
        adobeAccount = try container.decodeIfPresent(String.self, forKey: .adobeAccount) ?? ""
        detectedAdobeAccount = try container.decodeIfPresent(String.self, forKey: .detectedAdobeAccount) ?? ""
        adobePassword = try container.decodeIfPresent(String.self, forKey: .adobePassword) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "Active"
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(location, forKey: .location)
        try container.encode(machineName, forKey: .machineName)
        try container.encode(machineType, forKey: .machineType)
        try container.encode(customMachineType, forKey: .customMachineType)
        try container.encode(ram, forKey: .ram)
        try container.encode(customRAM, forKey: .customRAM)
        try container.encode(storage, forKey: .storage)
        try container.encode(freeSpace, forKey: .freeSpace)
        try container.encode(macOSVersion, forKey: .macOSVersion)
        try container.encode(serialNumber, forKey: .serialNumber)
        try container.encode(ipAddress, forKey: .ipAddress)
        try container.encode(installedOn, forKey: .installedOn)
        try container.encode(macUsername, forKey: .macUsername)
        try container.encode(adobeAccount, forKey: .adobeAccount)
        try container.encode(detectedAdobeAccount, forKey: .detectedAdobeAccount)
        try container.encode(adobePassword, forKey: .adobePassword)
        try container.encode(status, forKey: .status)
        try container.encode(notes, forKey: .notes)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }
}

// MARK: - Style

enum ShineStyle {
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.0)
}

enum InventoryDefaults {
    static let locations = [
        "Edit 1_Shine 1", "Edit 2_Shine 1", "Edit 3_Shine 1", "Edit 4_Shine 1",
        "Edit 5_Shine 1", "Edit 6_Shine 1", "Edit 7_Shine 1", "Edit 8_Shine 1",
        "Edit 9_Shine 2", "Edit 10_Shine 2", "Edit 11_Shine 2", "Edit 12_Shine 2",
        "Edit 13_Shine 2", "Edit 14_Shine 2", "Edit 15_Shine 2", "Edit 16_Shine 2",
        "Pitt 1_A_Shine 2", "Pitt 1_B_Shine 2", "Pitt 1_C_Shine 2", "Pitt 1_D_Shine 2",
        "Pitt 2_A_Shine 2", "Pitt 2_B_Shine 2", "Pitt 2_C_Shine 2", "Pitt 2_D_Shine 2",
        "Cave A", "Cave B", "Cave C", "Fishbowl", "Home"
    ]

    static let adobeAccounts = (1...25).map { "Production\($0)@ShineDC.com" }
}

enum AdobeBadgeColor {
    static let palette: [Color] = [
        ShineStyle.yellow,
        Color.blue,
        Color.purple,
        Color.green,
        Color.pink,
        Color.cyan,
        Color.mint,
        Color.indigo
    ]

    static func color(for account: String, isOverused: Bool) -> Color {
        if isOverused {
            return Color.orange
        }

        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !normalized.isEmpty else {
            return ShineStyle.yellow
        }

        let total = normalized.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }

        return palette[abs(total) % palette.count]
    }
}

// MARK: - Store

final class InventoryStore: ObservableObject {
    @Published var records: [ComputerRecord] = [] {
        didSet {
            guard !isLoading else { return }
            save()
        }
    }

    @Published var selectedRecordID: ComputerRecord.ID?
    @Published var lastSaveStatus: String = ""
    @Published var showVolumeNotMountedWarning = false
    @Published var volumeWarningMessage = ""
    @Published var isInventoryAvailable = true
    @Published var isTemporaryUnlockActive = false
    @Published var showScanOverwriteWarning = false
    @Published var pendingScannedMac: ScannedMacInfo?
    @Published var pendingScanWarningMessage = ""
    @Published var locationOptions: [String] = InventoryDefaults.locations {
        didSet {
            guard !isLoadingLocationOptions else { return }
            saveLocationOptions()
        }
    }

    private let fileManager = FileManager.default
    private var isLoadingLocationOptions = false
    private var isLoading = false
    private var hasShownVolumeWarning = false

    private var localBackupFolderURL: URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        return baseURL.appendingPathComponent("Shine Computer Inventory", isDirectory: true)
    }

    private var localBackupFileURL: URL {
        localBackupFolderURL.appendingPathComponent("ShineComputerInventory.json")
    }

    private var localLocationOptionsFileURL: URL {
        localBackupFolderURL.appendingPathComponent("ShineComputerLocations.json")
    }

    private var sharedVolumeURL: URL {
        AgentNetworkStorage.sharedVolumeURL
    }

    private var sharedStorageFolderURL: URL {
        AgentNetworkStorage.sharedStorageFolderURL
    }

    private var sharedStorageFileURL: URL {
        AgentNetworkStorage.sharedStorageFileURL
    }

    private var sharedLocationOptionsFileURL: URL {
        AgentNetworkStorage.sharedLocationOptionsFileURL
    }

    private var isSharedVolumeMounted: Bool {
        AgentNetworkStorage.isSharedVolumeMounted
    }

    private func showVolumeNotMountedAlertIfNeeded() {
        guard !hasShownVolumeWarning else { return }

        hasShownVolumeWarning = true
        volumeWarningMessage = "The SHINE-INTERNAL_1 volume is not mounted. This app cannot be used until that network volume is mounted."
        showVolumeNotMountedWarning = true
    }

    private var canEditInventory: Bool {
        isSharedVolumeMounted || isTemporaryUnlockActive
    }

    func activateTemporaryUnlock() {
        guard !isSharedVolumeMounted else {
            load()
            return
        }

        isTemporaryUnlockActive = true
        isInventoryAvailable = true
        showVolumeNotMountedWarning = false
        lastSaveStatus = "Temporary override active. SHINE-INTERNAL_1 is not mounted, so changes will not be saved."
    }

    init() {
        loadLocationOptions()
        load()
    }

    var selectedRecordBinding: Binding<ComputerRecord>? {
        guard let selectedRecordID else { return nil }
        guard records.contains(where: { $0.id == selectedRecordID }) else { return nil }

        return Binding(
            get: {
                self.records.first(where: { $0.id == selectedRecordID }) ?? ComputerRecord()
            },
            set: { updatedRecord in
                guard self.canEditInventory else {
                    self.isInventoryAvailable = false
                    self.showVolumeNotMountedAlertIfNeeded()
                    self.lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
                    return
                }

                guard let index = self.records.firstIndex(where: { $0.id == selectedRecordID }) else { return }

                let previousRecord = self.records[index]

                guard !previousRecord.isLocked else {
                    self.lastSaveStatus = "This computer entry is locked. Unlock it before making changes."
                    return
                }

                var record = updatedRecord

                if record.machineName != previousRecord.machineName {
                    let usernameWasBlank = previousRecord.macUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let usernameMatchedOldMachineName = previousRecord.macUsername == previousRecord.machineName

                    if usernameWasBlank || usernameMatchedOldMachineName {
                        record.macUsername = record.machineName
                    }
                }

                record.lastUpdated = Date()
                self.records[index] = record
            }
        )
    }

    func addRecord() {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        var record = ComputerRecord()
        record.machineName = ""
        record.macUsername = ""
        record.location = "Edit 1_Shine 1"
        record.lastUpdated = Date()
        records.append(record)
        selectedRecordID = record.id
        save()
    }

    func duplicateSelectedRecord() {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        guard let selectedRecordID,
              let record = records.first(where: { $0.id == selectedRecordID }) else { return }

        var copy = record
        copy.id = UUID()
        copy.machineName = record.machineName.isEmpty ? "Copy" : "\(record.machineName) Copy"
        copy.lastUpdated = Date()
        records.append(copy)
        self.selectedRecordID = copy.id
        save()
    }

    func setAllLocks(to locked: Bool) {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        guard !records.isEmpty else { return }

        for index in records.indices {
            records[index].isLocked = locked
            records[index].lastUpdated = Date()
        }

        save()
        lastSaveStatus = locked ? "Locked all computer entries." : "Unlocked all computer entries."
    }

    func deleteAllRecords() {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        records.removeAll()
        selectedRecordID = nil
        save()
        lastSaveStatus = "Deleted all computer entries from the shared inventory."
    }

    func toggleLock(for recordID: ComputerRecord.ID) {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }

        records[index].isLocked.toggle()
        records[index].lastUpdated = Date()
        save()
    }

    func deleteRecord(_ recordID: ComputerRecord.ID) {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        guard let record = records.first(where: { $0.id == recordID }) else { return }

        guard !record.isLocked else {
            lastSaveStatus = "This computer entry is locked. Unlock it before deleting."
            return
        }

        records.removeAll { $0.id == recordID }

        if selectedRecordID == recordID {
            selectedRecordID = records.first?.id
        }

        save()
    }

    func deleteSelectedRecord() {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        guard let recordIDToDelete = selectedRecordID else { return }
        deleteRecord(recordIDToDelete)
    }

    func scanThisMacIntoSelectedRecord() {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        let scanned = MacScanner.scan()
        let scannedSerial = scanned.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let scannedMachineName = scanned.machineName.trimmingCharacters(in: .whitespacesAndNewlines)

        if !scannedSerial.isEmpty,
           let matchingIndex = records.firstIndex(where: {
               !$0.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               $0.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(scannedSerial) == .orderedSame
           }) {
            guard !records[matchingIndex].isLocked else {
                selectedRecordID = records[matchingIndex].id
                lastSaveStatus = "This Mac already exists in the inventory, but that entry is locked."
                return
            }

            applyScan(scanned, toRecordAt: matchingIndex)
            selectedRecordID = records[matchingIndex].id
            save()
            lastSaveStatus = "Updated matching entry for \(scannedMachineName.isEmpty ? "this Mac" : scannedMachineName)."
            return
        }

        guard let selectedRecordID,
              let selectedIndex = records.firstIndex(where: { $0.id == selectedRecordID }) else {
            createRecordFromScan(scanned)
            return
        }

        let selectedRecord = records[selectedIndex]

        guard !selectedRecord.isLocked else {
            lastSaveStatus = "This computer entry is locked. Unlock it before scanning."
            return
        }

        if isBlankRecord(selectedRecord) {
            applyScan(scanned, toRecordAt: selectedIndex)
            save()
            lastSaveStatus = "Filled blank entry with \(scannedMachineName.isEmpty ? "this Mac" : scannedMachineName)."
            return
        }

        let selectedSerial = selectedRecord.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedMachineName = selectedRecord.machineName.trimmingCharacters(in: .whitespacesAndNewlines)

        let serialConflicts = !selectedSerial.isEmpty &&
            !scannedSerial.isEmpty &&
            selectedSerial.caseInsensitiveCompare(scannedSerial) != .orderedSame

        let nameConflicts = !selectedMachineName.isEmpty &&
            !scannedMachineName.isEmpty &&
            selectedMachineName.caseInsensitiveCompare(scannedMachineName) != .orderedSame

        if serialConflicts || nameConflicts {
            pendingScannedMac = scanned
            pendingScanWarningMessage = """
            This Mac appears to be \(scannedMachineName.isEmpty ? "a different computer" : scannedMachineName), but the selected entry is \(selectedMachineName.isEmpty ? "an existing computer" : selectedMachineName).

            Choose “Create New Entry” to add this Mac safely, or “Overwrite Selected” only if you are sure.
            """
            showScanOverwriteWarning = true
            return
        }

        applyScan(scanned, toRecordAt: selectedIndex)
        save()
        lastSaveStatus = "Updated selected entry with \(scannedMachineName.isEmpty ? "this Mac" : scannedMachineName)."
    }

    func overwriteSelectedWithPendingScan() {
        guard let scanned = pendingScannedMac,
              let selectedRecordID,
              let selectedIndex = records.firstIndex(where: { $0.id == selectedRecordID }) else {
            pendingScannedMac = nil
            return
        }

        guard !records[selectedIndex].isLocked else {
            lastSaveStatus = "This computer entry is locked. Unlock it before scanning."
            pendingScannedMac = nil
            return
        }

        applyScan(scanned, toRecordAt: selectedIndex)
        save()
        lastSaveStatus = "Overwrote selected entry with \(scanned.machineName.isEmpty ? "this Mac" : scanned.machineName)."
        pendingScannedMac = nil
    }

    func createRecordFromPendingScan() {
        guard let scanned = pendingScannedMac else { return }
        createRecordFromScan(scanned)
        pendingScannedMac = nil
    }

    private func createRecordFromScan(_ scanned: ScannedMacInfo) {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked."
            return
        }

        var record = ComputerRecord()
        record.location = "Edit 1_Shine 1"
        record.lastUpdated = Date()
        records.append(record)

        if let newIndex = records.firstIndex(where: { $0.id == record.id }) {
            applyScan(scanned, toRecordAt: newIndex)
            selectedRecordID = records[newIndex].id
        } else {
            selectedRecordID = record.id
        }

        save()
        lastSaveStatus = "Created new entry for \(scanned.machineName.isEmpty ? "this Mac" : scanned.machineName)."
    }

    private func isBlankRecord(_ record: ComputerRecord) -> Bool {
        [
            record.machineName,
            record.machineType,
            record.customMachineType,
            record.ram,
            record.customRAM,
            record.storage,
            record.freeSpace,
            record.macOSVersion,
            record.serialNumber,
            record.ipAddress,
            record.macUsername,
            record.adobeAccount,
            record.detectedAdobeAccount,
            record.adobePassword,
            record.notes
        ]
        .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func applyScan(_ scanned: ScannedMacInfo, toRecordAt index: Int) {
        var record = records[index]

        record.machineName = scanned.machineName

        applyScannedMachineType(scanned.machineType, to: &record)
        applyScannedRAM(scanned.ram, to: &record)
        applyScannedStorage(scanned.storage, to: &record)
        record.freeSpace = scanned.freeSpace

        record.macOSVersion = scanned.macOSVersion
        record.macUsername = scanned.macUsername
        record.detectedAdobeAccount = scanned.detectedAdobeAccount
        record.serialNumber = scanned.serialNumber
        record.ipAddress = scanned.ipAddress
        record.lastUpdated = Date()

        records[index] = record
    }

    private func applyScannedMachineType(_ scannedValue: String, to record: inout ComputerRecord) {
        let value = scannedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Apple ", with: "")

        guard !value.isEmpty else { return }

        let knownChipTypes = ["M1 Max", "M2 Max", "M2 Ultra", "M3 Max", "M3 Ultra"]

        if let knownChipType = knownChipTypes.first(where: { value.localizedCaseInsensitiveContains($0) }) {
            record.machineType = knownChipType
            record.customMachineType = ""
        } else {
            record.machineType = "Custom"
            record.customMachineType = value
        }
    }

    private func applyScannedRAM(_ scannedValue: String, to record: inout ComputerRecord) {
        let value = scannedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " GB", with: "GB")
            .replacingOccurrences(of: " TB", with: "TB")

        guard !value.isEmpty else { return }

        let knownRAM = ["16GB", "32GB", "64GB", "96GB", "128GB"]

        if let ram = knownRAM.first(where: { value.localizedCaseInsensitiveContains($0) }) {
            record.ram = ram
            record.customRAM = ""
        } else {
            record.ram = "Custom"
            record.customRAM = value
        }
    }

    private func applyScannedStorage(_ scannedValue: String, to record: inout ComputerRecord) {
        let value = scannedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")

        guard !value.isEmpty else { return }

        let knownStorage: [(label: String, gb: Double)] = [
            ("1TB", 1000),
            ("2TB", 2000),
            ("4TB", 4000)
        ]

        let normalized = value.uppercased()

        if let match = normalized.range(of: #"\d+(\.\d+)?(TB|GB)"#, options: .regularExpression) {
            let matchedValue = String(normalized[match])
            let unit = matchedValue.hasSuffix("TB") ? "TB" : "GB"
            let numberText = matchedValue
                .replacingOccurrences(of: "TB", with: "")
                .replacingOccurrences(of: "GB", with: "")

            if let number = Double(numberText) {
                let scannedGB = unit == "TB" ? number * 1000 : number
                let nearest = knownStorage.min { first, second in
                    abs(first.gb - scannedGB) < abs(second.gb - scannedGB)
                }

                if let nearest {
                    record.storage = nearest.label
                    return
                }
            }
        }

        if let exactStorage = knownStorage.first(where: { normalized.localizedCaseInsensitiveContains($0.label) }) {
            record.storage = exactStorage.label
        } else {
            record.storage = value
        }
    }


    func performAgentPing() -> AgentPingResult {
        guard AgentNetworkStorage.ensureSharedVolumeMounted() else {
            return AgentPingResult(
                success: false,
                message: "SHINE-INTERNAL_1 is not mounted and could not be auto-mounted.",
                updatedRecordName: nil
            )
        }

        do {
            return try AgentNetworkStorage.withInventoryFileLock(timeout: 15) {
                loadLocationOptions()
                load()

                let scanned = MacScanner.scan()
                let scannedSerial = scanned.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                let scannedMachineName = scanned.machineName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = scannedMachineName.isEmpty ? "this Mac" : scannedMachineName

                guard !scannedSerial.isEmpty || !scannedMachineName.isEmpty else {
                    return AgentPingResult(
                        success: false,
                        message: "Could not identify this Mac by serial number or machine name.",
                        updatedRecordName: nil
                    )
                }

                if !scannedSerial.isEmpty,
                   let matchingIndex = records.firstIndex(where: {
                       !$0.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                       $0.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(scannedSerial) == .orderedSame
                   }) {
                    applyScan(scanned, toRecordAt: matchingIndex)
                    selectedRecordID = records[matchingIndex].id
                    save()
                    return AgentPingResult(
                        success: true,
                        message: "Updated inventory scan for \(displayName).",
                        updatedRecordName: displayName
                    )
                }

                if !scannedMachineName.isEmpty,
                   let matchingIndex = records.firstIndex(where: {
                       !$0.machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                       $0.machineName.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(scannedMachineName) == .orderedSame
                   }) {
                    applyScan(scanned, toRecordAt: matchingIndex)
                    selectedRecordID = records[matchingIndex].id
                    save()
                    return AgentPingResult(
                        success: true,
                        message: "Updated inventory scan for \(displayName).",
                        updatedRecordName: displayName
                    )
                }

                var record = ComputerRecord()
                record.location = locationOptions.first ?? "Edit 1_Shine 1"
                record.status = "Active"
                record.lastUpdated = Date()
                records.append(record)

                guard let newIndex = records.firstIndex(where: { $0.id == record.id }) else {
                    return AgentPingResult(
                        success: false,
                        message: "Could not create a new inventory entry for \(displayName).",
                        updatedRecordName: nil
                    )
                }

                applyScan(scanned, toRecordAt: newIndex)
                selectedRecordID = records[newIndex].id
                save()

                return AgentPingResult(
                    success: true,
                    message: "Created new inventory scan entry for \(displayName).",
                    updatedRecordName: displayName
                )
            }
        } catch {
            return AgentPingResult(
                success: false,
                message: "Could not sync inventory because another write may be in progress: \(error.localizedDescription)",
                updatedRecordName: nil
            )
        }
    }

    func replaceLocationOptions(_ updatedLocations: [String], replacing oldLocations: [String]) {
        guard canEditInventory else {
            isInventoryAvailable = false
            showVolumeNotMountedAlertIfNeeded()
            lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Location list was not saved."
            return
        }

        let cleanedLocations = cleanedLocationOptions(updatedLocations)
        let finalLocations = cleanedLocations.isEmpty ? InventoryDefaults.locations : cleanedLocations

        var renameMap: [String: String] = [:]
        for index in oldLocations.indices {
            guard index < updatedLocations.count else { continue }
            let oldName = oldLocations[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = updatedLocations[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if !oldName.isEmpty, !newName.isEmpty, oldName != newName {
                renameMap[oldName] = newName
            }
        }

        if !renameMap.isEmpty {
            for index in records.indices {
                if let replacement = renameMap[records[index].location] {
                    records[index].location = replacement
                    records[index].lastUpdated = Date()
                }
            }
        }

        locationOptions = finalLocations
        save()
        lastSaveStatus = "Saved location list."
    }

    private func cleanedLocationOptions(_ options: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []

        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }

            seen.insert(key)
            cleaned.append(trimmed)
        }

        return cleaned
    }

    private func loadLocationOptions() {
        isLoadingLocationOptions = true
        defer { isLoadingLocationOptions = false }

        do {
            try fileManager.createDirectory(at: localBackupFolderURL, withIntermediateDirectories: true)

            let sourceURL: URL?
            if isSharedVolumeMounted, fileManager.fileExists(atPath: sharedLocationOptionsFileURL.path) {
                sourceURL = sharedLocationOptionsFileURL
            } else if fileManager.fileExists(atPath: localLocationOptionsFileURL.path) {
                sourceURL = localLocationOptionsFileURL
            } else {
                sourceURL = nil
            }

            guard let sourceURL else {
                locationOptions = InventoryDefaults.locations
                return
            }

            let data = try Data(contentsOf: sourceURL)
            let decoded = try JSONDecoder().decode([String].self, from: data)
            let cleaned = cleanedLocationOptions(decoded)
            locationOptions = cleaned.isEmpty ? InventoryDefaults.locations : cleaned

            if isSharedVolumeMounted {
                saveLocationOptions()
            }
        } catch {
            locationOptions = InventoryDefaults.locations
            lastSaveStatus = "Could not load location list: \(error.localizedDescription)"
        }
    }

    private func saveLocationOptions() {
        do {
            try fileManager.createDirectory(at: localBackupFolderURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cleanedLocationOptions(locationOptions))
            try data.write(to: localLocationOptionsFileURL, options: [.atomic])

            guard isSharedVolumeMounted else { return }

            try AgentNetworkStorage.withInventoryFileLock(timeout: 8) {
                try fileManager.createDirectory(at: sharedStorageFolderURL, withIntermediateDirectories: true)
                try data.write(to: sharedLocationOptionsFileURL, options: [.atomic])
            }
        } catch {
            lastSaveStatus = "Could not save location list: \(error.localizedDescription)"
        }
    }

    func load() {
        isLoading = true
        defer { isLoading = false }

        do {
            try fileManager.createDirectory(at: localBackupFolderURL, withIntermediateDirectories: true)

            guard isSharedVolumeMounted else {
                if isTemporaryUnlockActive {
                    isInventoryAvailable = true
                    lastSaveStatus = "Temporary override active. SHINE-INTERNAL_1 is not mounted, so changes will not be saved."
                } else {
                    isInventoryAvailable = false
                    records = []
                    selectedRecordID = nil
                    showVolumeNotMountedAlertIfNeeded()
                    lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory is locked until the network volume is mounted."
                }
                return
            }

            isInventoryAvailable = true
            isTemporaryUnlockActive = false
            hasShownVolumeWarning = false
            try fileManager.createDirectory(at: sharedStorageFolderURL, withIntermediateDirectories: true)
            loadLocationOptions()

            if !fileManager.fileExists(atPath: sharedStorageFileURL.path) {
                records = []
                selectedRecordID = nil
                lastSaveStatus = "Shared inventory file will be created at \(sharedStorageFileURL.path). Local backup: \(localBackupFileURL.path)"
                save()
                return
            }

            let data = try Data(contentsOf: sharedStorageFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([ComputerRecord].self, from: data).map { record in
                var updatedRecord = record
                updatedRecord.location = record.normalizedLocation

                let oldStarterValues = [
                    "New Computer",
                    "Shine",
                    "ShineNew Computer",
                    "Shine New Computer"
                ]

                if oldStarterValues.contains(updatedRecord.machineName) {
                    updatedRecord.machineName = ""
                }

                if oldStarterValues.contains(updatedRecord.macUsername) {
                    updatedRecord.macUsername = ""
                }

                return updatedRecord
            }
            selectedRecordID = records.first?.id

            saveLocalBackupOnly()
            lastSaveStatus = "Loaded shared inventory from \(sharedStorageFileURL.path). Local backup updated."
        } catch {
            records = []
            selectedRecordID = nil
            isInventoryAvailable = false
            lastSaveStatus = "Could not load shared inventory: \(error.localizedDescription)"
        }
    }

    func refreshFromSharedInventory() {
        let previouslySelectedID = selectedRecordID
        load()

        if let previouslySelectedID,
           records.contains(where: { $0.id == previouslySelectedID }) {
            selectedRecordID = previouslySelectedID
        } else {
            selectedRecordID = records.first?.id
        }

        if isInventoryAvailable {
            lastSaveStatus = "Refreshed shared inventory from \(sharedStorageFileURL.path)"
        }
    }

    private func encodedInventoryData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records)
    }

    private func saveLocalBackupOnly() {
        do {
            try fileManager.createDirectory(at: localBackupFolderURL, withIntermediateDirectories: true)
            let data = try encodedInventoryData()
            try data.write(to: localBackupFileURL, options: [.atomic])
        } catch {
            lastSaveStatus = "Could not save local backup: \(error.localizedDescription)"
        }
    }

    func save() {
        do {
            guard isSharedVolumeMounted else {
                if isTemporaryUnlockActive {
                    isInventoryAvailable = true
                    lastSaveStatus = "Temporary override active. Changes were not saved because SHINE-INTERNAL_1 is not mounted."
                } else {
                    isInventoryAvailable = false
                    showVolumeNotMountedAlertIfNeeded()
                    lastSaveStatus = "SHINE-INTERNAL_1 is not mounted. Inventory was not saved."
                }
                return
            }

            isInventoryAvailable = true
            isTemporaryUnlockActive = false
            hasShownVolumeWarning = false

            try fileManager.createDirectory(at: localBackupFolderURL, withIntermediateDirectories: true)

            try AgentNetworkStorage.withInventoryFileLock(timeout: 12) {
                try fileManager.createDirectory(at: sharedStorageFolderURL, withIntermediateDirectories: true)

                let data = try encodedInventoryData()
                try data.write(to: sharedStorageFileURL, options: [.atomic])
                try data.write(to: localBackupFileURL, options: [.atomic])
                saveLocationOptions()
            }

            lastSaveStatus = "Saved shared inventory to \(sharedStorageFileURL.path). Local backup updated."
        } catch {
            lastSaveStatus = "Could not save inventory: \(error.localizedDescription)"
        }
    }

    func exportCSV() {
        #if os(macOS)
        do {
            let desktopURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop", isDirectory: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

            let fileName = "ShineComputerInventory_\(formatter.string(from: Date())).csv"
            let csvURL = desktopURL.appendingPathComponent(fileName)

            let csv = CSVExporter.export(records: records)
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)

            lastSaveStatus = "Exported CSV to Desktop: \(fileName)"
            NSWorkspace.shared.activateFileViewerSelecting([csvURL])
        } catch {
            lastSaveStatus = "Could not export CSV: \(error.localizedDescription)"
        }
        #else
        lastSaveStatus = "CSV export is only available on macOS."
        #endif
    }
}

// MARK: - Scanner

struct ScannedMacInfo {
    var machineName: String
    var machineType: String
    var ram: String
    var storage: String
    var freeSpace: String
    var macOSVersion: String
    var macUsername: String
    var detectedAdobeAccount: String
    var serialNumber: String
    var ipAddress: String
}

enum MacScanner {
    static func scan() -> ScannedMacInfo {
        ScannedMacInfo(
            machineName: cleanMachineName(Host.current().localizedName ?? ProcessInfo.processInfo.hostName),
            machineType: chipTypeString(),
            ram: ramString(),
            storage: storageString(),
            freeSpace: freeSpaceString(),
            macOSVersion: macOSVersionString(),
            macUsername: NSUserName(),
            detectedAdobeAccount: AdobeAccountDetector.detectShineAdobeID(),
            serialNumber: serialNumber(),
            ipAddress: ipAddress()
        )
    }

    private static func cleanMachineName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        let possessiveMarkers = [
            "'s ",
            "’s "
        ]

        for marker in possessiveMarkers {
            if let range = name.range(of: marker, options: [.caseInsensitive]) {
                name = String(name[..<range.lowerBound])
                break
            }
        }

        let suffixes = [
            " Mac Studio",
            " MacBook Air",
            " MacBook Pro",
            " iMac",
            " Mac mini",
            " Mac Pro"
        ]

        for suffix in suffixes {
            if let range = name.range(of: suffix, options: [.caseInsensitive, .backwards]) {
                name = String(name[..<range.lowerBound])
                break
            }
        }

        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func chipTypeString() -> String {
        let chip = runShell("system_profiler SPHardwareDataType | awk -F': ' '/Chip/ {print $2; exit}'")
        if !chip.isEmpty {
            return chip
                .replacingOccurrences(of: "Apple ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let processor = runShell("system_profiler SPHardwareDataType | awk -F': ' '/Processor Name/ {print $2; exit}'")
        if !processor.isEmpty {
            return processor
                .replacingOccurrences(of: "Apple ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return runShell("sysctl -n machdep.cpu.brand_string")
            .replacingOccurrences(of: "Apple ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ramString() -> String {
        let systemProfilerRAM = runShell("system_profiler SPHardwareDataType | awk -F': ' '/Memory/ {print $2; exit}'")
        if !systemProfilerRAM.isEmpty {
            return systemProfilerRAM
                .replacingOccurrences(of: " GB", with: "GB")
                .replacingOccurrences(of: " TB", with: "TB")
        }

        let bytesString = runShell("sysctl -n hw.memsize")
        guard let bytes = Int64(bytesString) else { return "" }

        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1024 {
            let tb = gb / 1024.0
            return "\(Int(tb.rounded()))TB"
        }

        return "\(Int(gb.rounded()))GB"
    }

    private static func storageString() -> String {
        let diskInfo = runShell("diskutil info / | awk -F': *' '/Container Total Space|Disk Size/ {print $2; exit}'")
        if !diskInfo.isEmpty {
            if let match = diskInfo.range(of: #"\d+(\.\d+)?\s*(TB|GB)"#, options: .regularExpression) {
                return String(diskInfo[match])
                    .replacingOccurrences(of: " ", with: "")
            }

            return diskInfo
        }

        do {
            let homeURL = URL(fileURLWithPath: NSHomeDirectory())
            let resourceValues = try homeURL.resourceValues(forKeys: [.volumeTotalCapacityKey])

            if let total = resourceValues.volumeTotalCapacity {
                let gb = Double(total) / 1_000_000_000.0
                if gb >= 900 {
                    let tb = gb / 1000.0
                    return "\(Int(tb.rounded()))TB"
                }

                return "\(Int(gb.rounded()))GB"
            }
        } catch {
            return ""
        }

        return ""
    }


    private static func freeSpaceString() -> String {
        do {
            let homeURL = URL(fileURLWithPath: NSHomeDirectory())
            let keys: Set<URLResourceKey> = [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]
            let resourceValues = try homeURL.resourceValues(forKeys: keys)

            if let available = resourceValues.volumeAvailableCapacityForImportantUsage {
                return formatStorageBytes(available)
            }

            if let available = resourceValues.volumeAvailableCapacity {
                return formatStorageBytes(Int64(available))
            }
        } catch {
            return ""
        }

        return ""
    }

    private static func formatStorageBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }

        let gb = Double(bytes) / 1_000_000_000.0

        if gb >= 1000 {
            let tb = gb / 1000.0
            if tb >= 10 {
                return "\(Int(tb.rounded()))TB"
            }
            return String(format: "%.1fTB", tb)
        }

        return "\(Int(gb.rounded()))GB"
    }

    private static func macOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func serialNumber() -> String {
        runShell("ioreg -l | awk '/IOPlatformSerialNumber/ { print $4; }' | tr -d '\\\"'")
    }

    private static func ipAddress() -> String {
        runShell("ipconfig getifaddr en0 || ipconfig getifaddr en1")
    }

    private static func runShell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}


// MARK: - Adobe Account Detector

enum AdobeAccountDetector {
    static func detectShineAdobeID() -> String {
        autoreleasepool {
            let homeURL = FileManager.default.homeDirectoryForCurrentUser

            let specificAdobeFiles = [
                homeURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Adobe", isDirectory: true)
                    .appendingPathComponent("OOBE", isDirectory: true)
                    .appendingPathComponent("opm.db"),

                homeURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Adobe", isDirectory: true)
                    .appendingPathComponent("Common", isDirectory: true)
                    .appendingPathComponent("Team Projects Local Hub", isDirectory: true)
                    .appendingPathComponent("system.sqlite3")
            ]

            var foundEmails: [String] = []

            for fileURL in specificAdobeFiles {
                foundEmails.append(contentsOf: shineEmails(inFileAt: fileURL))
            }

            return bestShineEmail(from: foundEmails)
        }
    }

    private static func shineEmails(inFileAt fileURL: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let maxFileSizeBytes: UInt64 = 30 * 1024 * 1024

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value <= maxFileSizeBytes else {
            return []
        }

        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return []
        }

        return shineEmails(in: data)
    }

    private static func shineEmails(in data: Data) -> [String] {
        // Avoid shelling out to `strings`, because that can trigger the Xcode
        // Command Line Tools prompt on clean edit machines. Reading these Adobe
        // database/cache files directly has worked in testing and is safer.
        let encodings: [String.Encoding] = [.utf8, .ascii, .isoLatin1, .utf16LittleEndian, .utf16BigEndian]
        var foundEmails: [String] = []

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                foundEmails.append(contentsOf: matches(
                    in: text,
                    pattern: #"[A-Z0-9._%+-]+@shinedc\.com"#,
                    options: [.caseInsensitive]
                ))
            }
        }

        return unique(foundEmails)
    }

    private static func bestShineEmail(from emails: [String]) -> String {
        let uniqueEmails = unique(emails.map { canonicalizedShineEmail($0) })

        guard !uniqueEmails.isEmpty else { return "" }

        if let productionEmail = uniqueEmails.first(where: {
            $0.range(of: #"^Production\d+@ShineDC\.com$"#, options: [.regularExpression]) != nil
        }) {
            return productionEmail
        }

        return uniqueEmails[0]
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()

            guard !key.isEmpty, !seen.contains(key) else { continue }

            seen.insert(key)
            output.append(trimmed)
        }

        return output
    }

    private static func matches(in text: String, pattern: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func canonicalizedShineEmail(_ email: String) -> String {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let range = lower.range(of: #"^production(\d+)@shinedc\.com$"#, options: .regularExpression) {
            let matched = String(lower[range])
            let number = matched
                .replacingOccurrences(of: "production", with: "")
                .replacingOccurrences(of: "@shinedc.com", with: "")
            return "Production\(number)@ShineDC.com"
        }

        if let atIndex = lower.firstIndex(of: "@") {
            let localPart = String(lower[..<atIndex])
            return "\(localPart)@ShineDC.com"
        }

        return lower
    }
}

// MARK: - CSV Export

enum CSVExporter {
    static func export(records: [ComputerRecord]) -> String {
        let header = [
            "Location",
            "Machine Name",
            "Chip Type",
            "RAM",
            "Storage",
            "Free Space",
            "macOS Version",
            "Serial Number",
            "IP Address",
            "Installed On",
            "macOS Username",
            "Adobe Account",
            "Detected Adobe Account",
            "Adobe Password",
            "Status",
            "Notes",
            "Last Updated"
        ]

        let rows = records.map { record in
            [
                record.location,
                record.machineName,
                record.displayMachineType,
                record.displayRAM,
                record.storage,
                record.freeSpace,
                record.macOSVersion,
                record.serialNumber,
                record.ipAddress,
                record.installedOn,
                record.macUsername,
                record.adobeAccount,
                record.detectedAdobeAccount,
                record.adobePassword,
                record.status,
                record.notes,
                DateFormatter.inventoryDateTime.string(from: record.lastUpdated)
            ]
        }

        func csvEscape(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        return ([header] + rows)
            .map { row in row.map { csvEscape($0) }.joined(separator: ",") }
            .joined(separator: "\n")
    }
}


// MARK: - Views

struct ContentView: View {
    @EnvironmentObject private var store: InventoryStore
    @EnvironmentObject private var agent: InventoryAgentController
    @State private var searchText = ""
    @State private var sidebarWidth: CGFloat = 380
    @State private var showFilter = "All Computers"
    @State private var sortOption = "Location"

    private var filteredRecords: [ComputerRecord] {
        let showFiltered = store.records.filter { record in
            switch showFilter {
            case "All Computers":
                return true
            case "Shine 1 Computers":
                return record.normalizedLocation.hasSuffix("_Shine 1")
            case "Shine 2 Computers":
                return record.normalizedLocation.hasSuffix("_Shine 2")
            case "Home":
                return record.location == "Home"
            case "Inactive Computers":
                return record.status != "Active"
            default:
                return record.displayMachineType == showFilter
            }
        }

        let searched: [ComputerRecord]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searched = showFiltered
        } else {
            let query = searchText.lowercased()
            searched = showFiltered.filter { $0.searchableText.contains(query) }
        }

        return sortedRecords(searched)
    }

    private func sortedRecords(_ records: [ComputerRecord]) -> [ComputerRecord] {
        func locationNameTieBreak(_ first: ComputerRecord, _ second: ComputerRecord) -> Bool {
            if first.normalizedLocation == second.normalizedLocation {
                return first.machineName.localizedCaseInsensitiveCompare(second.machineName) == .orderedAscending
            }
            return first.normalizedLocation.localizedCaseInsensitiveCompare(second.normalizedLocation) == .orderedAscending
        }

        func freeSpaceGB(_ value: String) -> Double? {
            let cleaned = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .replacingOccurrences(of: " ", with: "")

            guard !cleaned.isEmpty else { return nil }

            if let match = cleaned.range(of: #"\d+(\.\d+)?(TB|GB|MB)"#, options: .regularExpression) {
                let matchedValue = String(cleaned[match])
                let unit: String
                if matchedValue.hasSuffix("TB") {
                    unit = "TB"
                } else if matchedValue.hasSuffix("MB") {
                    unit = "MB"
                } else {
                    unit = "GB"
                }

                let numberText = matchedValue
                    .replacingOccurrences(of: "TB", with: "")
                    .replacingOccurrences(of: "GB", with: "")
                    .replacingOccurrences(of: "MB", with: "")

                guard let number = Double(numberText) else { return nil }

                switch unit {
                case "TB":
                    return number * 1000
                case "MB":
                    return number / 1000
                default:
                    return number
                }
            }

            return nil
        }

        switch sortOption {
        case "Machine Name":
            return records.sorted {
                let first = $0.machineName.trimmingCharacters(in: .whitespacesAndNewlines)
                let second = $1.machineName.trimmingCharacters(in: .whitespacesAndNewlines)

                if first.isEmpty != second.isEmpty {
                    return !first.isEmpty
                }

                if first.caseInsensitiveCompare(second) == .orderedSame {
                    return locationNameTieBreak($0, $1)
                }

                return first.localizedCaseInsensitiveCompare(second) == .orderedAscending
            }
        case "Free Space: Low to High":
            return records.sorted {
                let first = freeSpaceGB($0.freeSpace)
                let second = freeSpaceGB($1.freeSpace)

                if first == nil && second == nil {
                    return locationNameTieBreak($0, $1)
                }

                if first == nil { return false }
                if second == nil { return true }

                if first == second {
                    return locationNameTieBreak($0, $1)
                }

                return (first ?? 0) < (second ?? 0)
            }
        case "Free Space: High to Low":
            return records.sorted {
                let first = freeSpaceGB($0.freeSpace)
                let second = freeSpaceGB($1.freeSpace)

                if first == nil && second == nil {
                    return locationNameTieBreak($0, $1)
                }

                if first == nil { return false }
                if second == nil { return true }

                if first == second {
                    return locationNameTieBreak($0, $1)
                }

                return (first ?? 0) > (second ?? 0)
            }
        case "Last Updated":
            return records.sorted {
                if $0.lastUpdated == $1.lastUpdated {
                    return locationNameTieBreak($0, $1)
                }

                return $0.lastUpdated > $1.lastUpdated
            }
        case "Status":
            return records.sorted {
                if $0.status.caseInsensitiveCompare($1.status) == .orderedSame {
                    return locationNameTieBreak($0, $1)
                }

                return $0.status.localizedCaseInsensitiveCompare($1.status) == .orderedAscending
            }
        case "Detected Adobe ID":
            return records.sorted {
                let first = $0.detectedAdobeAccount.trimmingCharacters(in: .whitespacesAndNewlines)
                let second = $1.detectedAdobeAccount.trimmingCharacters(in: .whitespacesAndNewlines)

                if first.isEmpty != second.isEmpty {
                    return !first.isEmpty
                }

                if first.caseInsensitiveCompare(second) == .orderedSame {
                    return locationNameTieBreak($0, $1)
                }

                return first.localizedCaseInsensitiveCompare(second) == .orderedAscending
            }
        default:
            return records.sorted(by: locationNameTieBreak)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(searchText: $searchText)
                .disabled(!store.isInventoryAvailable)

            Rectangle()
                .fill(ShineStyle.yellow)
                .frame(height: 3)

            ConnectedComputersSummaryView(records: store.records)
                .environmentObject(agent)
                .disabled(!store.isInventoryAvailable)

            if store.isTemporaryUnlockActive {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Temporary override active — SHINE-INTERNAL_1 is not mounted. Changes will not be saved.")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange)
            }

            HStack(spacing: 0) {
                SidebarView(records: filteredRecords, allRecords: store.records, showFilter: $showFilter, sortOption: $sortOption)
                    .frame(width: sidebarWidth)

                ResizableDivider(sidebarWidth: $sidebarWidth)

                if let binding = store.selectedRecordBinding {
                    DetailView(record: binding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .disabled(!store.isInventoryAvailable)
            .overlay {
                if !store.isInventoryAvailable {
                    LockedInventoryView()
                }
            }

            Rectangle()
                .fill(ShineStyle.yellow.opacity(0.65))
                .frame(height: 1)

            FooterView()
        }
        .alert("SHINE-INTERNAL_1 Not Mounted", isPresented: $store.showVolumeNotMountedWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.volumeWarningMessage)
        }
        .alert("Scan This Mac Warning", isPresented: $store.showScanOverwriteWarning) {
            Button("Cancel", role: .cancel) {
                store.pendingScannedMac = nil
            }

            Button("Create New Entry") {
                store.createRecordFromPendingScan()
            }

            Button("Overwrite Selected", role: .destructive) {
                store.overwriteSelectedWithPendingScan()
            }
        } message: {
            Text(store.pendingScanWarningMessage)
        }

    }
}

struct ConnectedComputersSummaryView: View {
    @EnvironmentObject private var agent: InventoryAgentController
    let records: [ComputerRecord]
    @State private var showConnectedList = false

    private var statusText: String {
        if !AgentNetworkStorage.isSharedVolumeMounted {
            return "Server not connected"
        }

        if agent.visibleConnectedAgents.isEmpty {
            return "No active agents found"
        }

        return "\(agent.visibleConnectedAgentCount) connected"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(ShineStyle.yellow)

            Text("Connected Computers: \(agent.visibleConnectedAgentCount)")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("View List…") {
                agent.refreshPresenceStatus(writeHeartbeat: true)
                showConnectedList = true
            }
            .font(.caption)
            .disabled(agent.visibleConnectedAgents.isEmpty)
            .help(agent.visibleConnectedAgents.isEmpty ? "Connected agents will appear when helper apps are running on the network." : "Show connected computer names, locations, and last seen times.")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18))
        .sheet(isPresented: $showConnectedList) {
            ConnectedComputersListView(records: records)
                .environmentObject(agent)
        }
    }
}

struct ConnectedComputersListView: View {
    @EnvironmentObject private var agent: InventoryAgentController
    @Environment(\.dismiss) private var dismiss
    let records: [ComputerRecord]

    private func matchingRecord(for presence: AgentPresence) -> ComputerRecord? {
        let serial = presence.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineName = presence.machineName.trimmingCharacters(in: .whitespacesAndNewlines)

        if !serial.isEmpty,
           let match = records.first(where: { $0.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(serial) == .orderedSame }) {
            return match
        }

        if !machineName.isEmpty,
           let match = records.first(where: { $0.machineName.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(machineName) == .orderedSame }) {
            return match
        }

        return nil
    }

    private var sortedAgents: [AgentPresence] {
        agent.visibleConnectedAgents.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected Computers")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(ShineStyle.yellow)

                    Text("\(agent.visibleConnectedAgentCount) active helper agent\(agent.visibleConnectedAgentCount == 1 ? "" : "s") connected to SHINE-INTERNAL_1")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Refresh") {
                    agent.refreshPresenceStatus(writeHeartbeat: true)
                }

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            if sortedAgents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: AgentNetworkStorage.isSharedVolumeMounted ? "desktopcomputer" : "externaldrive.badge.exclamationmark")
                        .font(.system(size: 38))
                        .foregroundStyle(ShineStyle.yellow)

                    Text(AgentNetworkStorage.isSharedVolumeMounted ? "No connected agents found" : "SHINE-INTERNAL_1 is not connected")
                        .font(.headline)

                    Text(AgentNetworkStorage.isSharedVolumeMounted ? "Connected computers will appear here when their helper apps are running and checked in recently." : "Mount the server and refresh to see connected computers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                List(sortedAgents) { presence in
                    let record = matchingRecord(for: presence)
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(ShineStyle.yellow)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(presence.displayName)
                                .font(.headline)
                                .lineLimit(1)

                            Text(record?.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? record!.location : "Location unknown")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Last seen")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text(presence.lastSeenText)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .padding(18)
        .frame(width: 620, height: 460)
    }
}

struct HeaderView: View {
    @EnvironmentObject private var store: InventoryStore
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shine Computer Inventory")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(ShineStyle.yellow)

                Text("Track computer locations, usernames, Adobe accounts, and storage.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }

            Spacer()

            TextField("Search inventory…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            Button("Export CSV") {
                store.exportCSV()
            }
        }
        .padding(16)
    }
}


struct AdobeAccountBadge: View {
    let record: ComputerRecord
    let count: Int

    private var isOverused: Bool {
        count > 2
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOverused ? "exclamationmark.triangle.fill" : "person.2.fill")

            Text(isOverused ? "Adobe \(record.adobeAccountShortName) x\(count)" : "Adobe \(record.adobeAccountShortName)")
                .lineLimit(1)
        }
        .font(.caption)
        .fontWeight(.semibold)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(Color.black)
        .background(AdobeBadgeColor.color(for: record.normalizedAdobeAccount, isOverused: isOverused))
        .clipShape(Capsule())
        .help(isOverused ? "This Adobe account is used on \(count) computers." : "This Adobe account is shared by \(count) computers.")
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: InventoryStore
    let records: [ComputerRecord]
    let allRecords: [ComputerRecord]
    @Binding var showFilter: String
    @Binding var sortOption: String
    @State private var recordPendingDelete: ComputerRecord?
    @State private var showBulkLockWarning = false
    @State private var showDeleteAllWarning = false
    @State private var pendingBulkLockState = true

    private let showOptions = [
        "All Computers",
        "Shine 1 Computers",
        "Shine 2 Computers",
        "Home",
        "M1 Max",
        "M2 Max",
        "M2 Ultra",
        "M3 Max",
        "M3 Ultra",
        "iMac",
        "Cheese Grater",
        "Inactive Computers"
    ]

    private let sortOptions = [
        "Location",
        "Machine Name",
        "Free Space: Low to High",
        "Free Space: High to Low",
        "Last Updated",
        "Status",
        "Detected Adobe ID"
    ]

    private func adobeAccountCount(for record: ComputerRecord) -> Int {
        let account = record.normalizedAdobeAccount

        guard !account.isEmpty else {
            return 0
        }

        return allRecords.filter { $0.normalizedAdobeAccount == account }.count
    }

    private var selectedAdobeAccount: String {
        guard let selectedRecordID = store.selectedRecordID,
              let selectedRecord = allRecords.first(where: { $0.id == selectedRecordID }) else {
            return ""
        }

        return selectedRecord.normalizedAdobeAccount
    }

    private func sharesSelectedAdobeAccount(_ record: ComputerRecord) -> Bool {
        let account = record.normalizedAdobeAccount

        guard !account.isEmpty,
              !selectedAdobeAccount.isEmpty,
              account == selectedAdobeAccount,
              record.id != store.selectedRecordID,
              adobeAccountCount(for: record) >= 2 else {
            return false
        }

        return true
    }

    private func adobeMatchHighlightColor(for record: ComputerRecord) -> Color {
        AdobeBadgeColor.color(
            for: record.normalizedAdobeAccount,
            isOverused: adobeAccountCount(for: record) > 2
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Computers")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(records, selection: $store.selectedRecordID) { record in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.location.isEmpty ? "No location set" : record.location)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(record.machineName.isEmpty ? "No machine name set" : record.machineName)
                                .font(.subheadline)
                                .foregroundStyle(ShineStyle.yellow)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Button {
                            let modifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

                            if modifierFlags.contains(.command) {
                                pendingBulkLockState = !record.isLocked
                                showBulkLockWarning = true
                            } else {
                                store.toggleLock(for: record.id)
                            }
                        } label: {
                            Image(systemName: record.isLocked ? "lock.fill" : "lock.open")
                                .foregroundStyle(record.isLocked ? ShineStyle.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(record.isLocked ? "Unlock this computer entry. Command-click to unlock all entries." : "Lock this computer entry. Command-click to lock all entries.")

                        Button {
                            let modifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

                            if modifierFlags.contains(.command) {
                                showDeleteAllWarning = true
                            } else if !record.isLocked {
                                recordPendingDelete = record
                            } else {
                                store.lastSaveStatus = "This computer entry is locked. Unlock it before deleting."
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(record.isLocked ? Color.secondary.opacity(0.45) : Color.red)
                        }
                        .buttonStyle(.plain)
                        .help(record.isLocked ? "Unlock this entry before deleting. Command-click to delete all entries." : "Delete this computer entry. Command-click to delete all entries.")
                    }

                    HStack(spacing: 12) {
                        let adobeCount = adobeAccountCount(for: record)

                        if adobeCount >= 2 {
                            AdobeAccountBadge(record: record, count: adobeCount)
                        }

                        if !record.displayMachineType.isEmpty {
                            Label(record.displayMachineType, systemImage: "desktopcomputer")
                                .lineLimit(1)
                        }

                        if !record.displayRAM.isEmpty {
                            Label(record.displayRAM, systemImage: "memorychip")
                                .lineLimit(1)
                        }

                        if !record.storage.isEmpty || !record.freeSpace.isEmpty {
                            let storageText = record.storage.trimmingCharacters(in: .whitespacesAndNewlines)
                            let freeText = record.freeSpace.trimmingCharacters(in: .whitespacesAndNewlines)
                            let combinedStorageText: String = {
                                if !storageText.isEmpty && !freeText.isEmpty {
                                    return "\(storageText) | \(freeText) Free"
                                }

                                if !storageText.isEmpty {
                                    return storageText
                                }

                                return "\(freeText) Free"
                            }()

                            Label(combinedStorageText, systemImage: "internaldrive")
                                .lineLimit(1)
                        }

                        if record.isLocked {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(Color.secondary)

                                Text("Locked")
                                    .foregroundStyle(Color.secondary)
                            }
                            .lineLimit(1)
                        }

                        if record.status != "Active" {
                            Label(record.status, systemImage: "exclamationmark.circle")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 6)
                .padding(.horizontal, sharesSelectedAdobeAccount(record) ? 8 : 0)
                .background {
                    if sharesSelectedAdobeAccount(record) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(adobeMatchHighlightColor(for: record).opacity(0.18))
                    }
                }
                .overlay(alignment: .leading) {
                    if sharesSelectedAdobeAccount(record) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(adobeMatchHighlightColor(for: record))
                            .frame(width: 4)
                    }
                }
                .tag(record.id)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("View:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)

                    Picker("View", selection: $showFilter) {
                        ForEach(showOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Text("Sort:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)

                    Picker("Sort", selection: $sortOption) {
                        ForEach(sortOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Delete Computer Entry?", isPresented: Binding(
            get: { recordPendingDelete != nil },
            set: { if !$0 { recordPendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                recordPendingDelete = nil
            }

            Button("Delete", role: .destructive) {
                if let recordPendingDelete {
                    store.deleteRecord(recordPendingDelete.id)
                }
                recordPendingDelete = nil
            }
        } message: {
            Text("This will remove the selected computer from the shared inventory JSON.")
        }
        .alert(pendingBulkLockState ? "Lock All Entries?" : "Unlock All Entries?", isPresented: $showBulkLockWarning) {
            Button("Cancel", role: .cancel) {}

            Button(pendingBulkLockState ? "Lock All" : "Unlock All") {
                store.setAllLocks(to: pendingBulkLockState)
            }
        } message: {
            Text(pendingBulkLockState ? "You are about to lock all computer entries in the shared inventory." : "You are about to unlock all computer entries in the shared inventory.")
        }
        .alert("Delete All Entries?", isPresented: $showDeleteAllWarning) {
            Button("Cancel", role: .cancel) {}

            Button("Delete All", role: .destructive) {
                store.deleteAllRecords()
            }
        } message: {
            Text("You are about to permanently delete ALL computer entries from the shared inventory JSON. This cannot be undone.")
        }
    }
}

struct LockPillButton: View {
    let isLocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .fontWeight(.semibold)

                Text(isLocked ? "Locked" : "Unlocked")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(isLocked ? Color.black : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isLocked ? ShineStyle.yellow : Color.secondary.opacity(0.16))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isLocked ? "Unlock this computer entry" : "Lock this computer entry")
    }
}

struct LockedDetailOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            VStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(ShineStyle.yellow)

                Text("This entry is locked")
                    .font(.headline)

                Text("Use the Locked pill at the top to unlock before editing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 10)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var store: InventoryStore
    @Binding var record: ComputerRecord

    @State private var showLocationEditor = false
    @State private var showDeleteSelectedWarning = false

    private let statuses = ["Active", "Offline", "Repair", "Retired", "Spare"]
    private let machineTypes = ["M1 Max", "M2 Max", "M2 Ultra", "M3 Max", "M3 Ultra", "Custom"]
    private let ramOptions = ["16GB", "32GB", "64GB", "96GB", "128GB", "Custom"]
    private let storageOptions = ["1TB", "2TB", "4TB"]

    private var currentLocationOptions: [String] {
        var options = store.locationOptions
        let current = record.location.trimmingCharacters(in: .whitespacesAndNewlines)

        if !current.isEmpty && !options.contains(current) {
            options.insert(current, at: 0)
        }

        return options
    }

    private var adobeAccountOptions: [String] {
        var options = InventoryDefaults.adobeAccounts
        let current = record.adobeAccount.trimmingCharacters(in: .whitespacesAndNewlines)

        if !current.isEmpty && !options.contains(current) {
            options.insert(current, at: 0)
        }

        return options
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.machineName.isEmpty ? "No machine name set" : record.machineName)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Last updated: \(DateFormatter.inventoryDateTime.string(from: record.lastUpdated))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    LockPillButton(isLocked: record.isLocked) {
                        store.toggleLock(for: record.id)
                    }

                    Menu("Actions…") {
                        Button("Sync This Mac Now") {
                            store.scanThisMacIntoSelectedRecord()
                        }
                        .disabled(record.isLocked)

                        Button("Add Machine") {
                            store.addRecord()
                        }
                        .keyboardShortcut("n", modifiers: [.command])

                        Divider()

                        Button(role: .destructive) {
                            showDeleteSelectedWarning = true
                        } label: {
                            Text("Delete Machine…")
                        }
                        .disabled(record.isLocked)
                    }
                }

                if record.isLocked {
                    Text("Unlock this entry from the left list before editing details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ZStack {
                    VStack(alignment: .leading, spacing: 18) {
                        GroupBox("Location") {
                            FormGrid {
                                LocationPickerRow(
                                    selection: $record.location,
                                    options: currentLocationOptions,
                                    onEdit: { showLocationEditor = true }
                                )
                                LabeledPicker("Status", selection: $record.status, options: statuses, width: 260)
                            }
                        }

                        GroupBox("Computer") {
                            FormGrid {
                                LabeledTextField("Machine Name", text: $record.machineName, placeholder: "Machine Name")
                                LabeledPicker("Chip Type", selection: $record.machineType, options: machineTypes, width: 260)
                                if record.machineType == "Custom" {
                                    LabeledTextField("Custom Chip", text: $record.customMachineType, placeholder: "Enter custom chip type")
                                }
                                LabeledPicker("RAM", selection: $record.ram, options: ramOptions, width: 260)
                                if record.ram == "Custom" {
                                    LabeledTextField("Custom RAM", text: $record.customRAM, placeholder: "Enter custom RAM")
                                }
                                LabeledPicker("Storage", selection: $record.storage, options: storageOptions, width: 200)
                                LabeledReadOnlyText("Free Space", text: record.freeSpace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : record.freeSpace, leadingInset: 6, isDimmed: true)
                                LabeledTextField("macOS Version", text: $record.macOSVersion, placeholder: "macOS 26.x")
                                LabeledTextField("Serial Number", text: $record.serialNumber, placeholder: "Serial number")
                                LabeledTextField("IP Address", text: $record.ipAddress, placeholder: "192.168.x.x")
                                LabeledDatePicker("Installed On", text: $record.installedOn)
                            }
                        }

                        GroupBox("Users & Accounts") {
                            FormGrid {
                                LabeledTextField("macOS Username", text: $record.macUsername, placeholder: "Username")
                                LabeledPicker("Adobe Account", selection: $record.adobeAccount, options: adobeAccountOptions, width: 260)
                                LabeledReadOnlyText("Detected Adobe ID", text: record.detectedAdobeAccount.isEmpty ? "Not detected" : record.detectedAdobeAccount)
                                if !record.detectedAdobeAccount.isEmpty && !record.adobeAccount.isEmpty && record.detectedAdobeAccount.caseInsensitiveCompare(record.adobeAccount) != .orderedSame {
                                    LabeledWarningText("Adobe ID Mismatch", text: "Detected ID does not match selected Adobe Account")
                                }
                                LabeledTextField("Adobe Password", text: $record.adobePassword, placeholder: "Password")
                            }
                        }

                        GroupBox("Notes") {
                            TextEditor(text: $record.notes)
                                .font(.body)
                                .frame(minHeight: 120)
                                .padding(4)
                        }
                    }
                    .disabled(record.isLocked)
                    .allowsHitTesting(!record.isLocked)
                    .opacity(record.isLocked ? 0.55 : 1.0)

                    if record.isLocked {
                        LockedDetailOverlay()
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showLocationEditor) {
            LocationEditorView()
                .environmentObject(store)
        }
        .alert("Delete Machine?", isPresented: $showDeleteSelectedWarning) {
            Button("Cancel", role: .cancel) {}

            Button("Delete", role: .destructive) {
                store.deleteSelectedRecord()
            }
        } message: {
            Text("This will remove the selected computer from the shared inventory JSON.")
        }
    }
}

struct LockedInventoryView: View {
    @EnvironmentObject private var store: InventoryStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(ShineStyle.yellow)

                Text("SHINE-INTERNAL_1 Not Mounted")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text("Mount /Volumes/SHINE-INTERNAL_1 to use the shared Shine Computer Inventory.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button("Check Again") {
                    let modifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

                    if modifierFlags.contains(.command) && modifierFlags.contains(.shift) {
                        store.activateTemporaryUnlock()
                    } else {
                        store.load()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .help("Check for the shared volume. Hidden override: Command + Shift + click to temporarily unlock without saving.")
            }
            .padding(28)
            .frame(maxWidth: 460)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 18)
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var store: InventoryStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(ShineStyle.yellow)

            Text("No computer selected")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Add a machine to start building the Shine inventory.")
                .foregroundStyle(.secondary)

            Button("Add Machine") {
                store.addRecord()
            }
        }
    }
}

struct FooterView: View {
    @EnvironmentObject private var store: InventoryStore

    var body: some View {
        HStack(spacing: 12) {
            Text("\(store.records.count) machine\(store.records.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)

            Text(store.lastSaveStatus)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text("Shine Computer Inventory v1.0")
                .foregroundStyle(.secondary.opacity(0.85))
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ResizableDivider: View {
    @Binding var sidebarWidth: CGFloat
    @State private var dragStartWidth: CGFloat?

    private let minWidth: CGFloat = 260
    private let maxWidth: CGFloat = 560

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 1)

            Rectangle()
                .fill(Color.clear)
                .frame(width: 12)
                .contentShape(Rectangle())
        }
        .frame(width: 12)
        .onHover { hovering in
            #if os(macOS)
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
            #endif
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = sidebarWidth
                    }

                    let baseWidth = dragStartWidth ?? sidebarWidth
                    let newWidth = baseWidth + value.translation.width
                    sidebarWidth = min(max(newWidth, minWidth), maxWidth)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }
}

// MARK: - Form Helpers

struct FormGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            content
        }
        .padding(12)
    }
}



struct LabeledReadOnlyText: View {
    let title: String
    let text: String
    let leadingInset: CGFloat
    let isDimmed: Bool

    init(_ title: String, text: String, leadingInset: CGFloat = 0, isDimmed: Bool = false) {
        self.title = title
        self.text = text
        self.leadingInset = leadingInset
        self.isDimmed = isDimmed
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            Text(text)
                .foregroundStyle(isDimmed || text == "Not detected" || text == "Unknown" ? .secondary : .primary)
                .padding(.leading, leadingInset)
                .frame(minWidth: 420, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

struct LabeledWarningText: View {
    let title: String
    let text: String

    init(_ title: String, text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ShineStyle.yellow)

                Text(text)
                    .foregroundStyle(ShineStyle.yellow)
            }
            .font(.caption)
            .frame(minWidth: 420, alignment: .leading)
        }
    }
}

struct LabeledTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    init(_ title: String, text: Binding<String>, placeholder: String = "") {
        self.title = title
        self._text = text
        self.placeholder = placeholder
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 420)
        }
    }
}

struct LocationPickerRow: View {
    @Binding var selection: String
    let options: [String]
    let onEdit: () -> Void

    var body: some View {
        GridRow {
            Text("Location")
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            HStack(spacing: 8) {
                Picker("", selection: $selection) {
                    Text("Select…").tag("")
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 260, alignment: .leading)

                Button("Edit…", action: onEdit)
                    .help("Edit or delete location names")
            }
        }
    }
}

struct LocationEditorView: View {
    @EnvironmentObject private var store: InventoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftLocations: [String] = []
    @State private var originalLocations: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Locations")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Rename, delete, add, or drag locations into the order you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(draftLocations.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .help("Drag this row to reorder locations")

                        TextField("Location name", text: Binding(
                            get: { draftLocations[index] },
                            set: { draftLocations[index] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button {
                            draftLocations.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this location name")
                    }
                    .padding(.vertical, 3)
                }
                .onMove { offsets, destination in
                    draftLocations.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .frame(minHeight: 300)

            HStack {
                Button {
                    draftLocations.append("New Location")
                } label: {
                    Label("Add Location", systemImage: "plus")
                }

                Spacer()

                Button("Reset Defaults") {
                    draftLocations = InventoryDefaults.locations
                }

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    store.replaceLocationOptions(draftLocations, replacing: originalLocations)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
        .onAppear {
            DispatchQueue.main.async {
                originalLocations = store.locationOptions
                draftLocations = store.locationOptions
            }
        }
    }
}

struct LabeledPicker: View {
    let title: String
    @Binding var selection: String
    let options: [String]
    let width: CGFloat

    init(_ title: String, selection: Binding<String>, options: [String], width: CGFloat = 220) {
        self.title = title
        self._selection = selection
        self.options = options
        self.width = width
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            Picker("", selection: $selection) {
                Text("Select…").tag("")
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: width, alignment: .leading)
        }
    }
}



struct LabeledStoragePicker: View {
    @Binding var selection: String
    let freeSpace: String
    let options: [String]
    let width: CGFloat

    private var cleanedFreeSpace: String {
        let value = freeSpace.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Unknown" : value
    }

    private var hasFreeSpaceValue: Bool {
        !freeSpace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GridRow {
            Text("Storage")
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            ZStack(alignment: .leading) {
                Picker("", selection: $selection) {
                    Text("Select…").tag("")
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: width, alignment: .leading)

                if hasFreeSpaceValue {
                    HStack(spacing: 5) {
                        Text("Free:")
                        Text(cleanedFreeSpace)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: width + 14)
                }
            }
            .frame(width: width + 150, alignment: .leading)
            .gridCellUnsizedAxes(.horizontal)
        }
    }
}

struct LabeledDatePicker: View {
    let title: String
    @Binding var text: String
    @State private var selectedDate: Date = Date()
    @State private var showCalendar = false

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            HStack(spacing: 8) {
                Button(text.isEmpty ? "Select Date…" : text) {
                    selectedDate = DateFormatter.installedOnDate.date(from: text) ?? Date()
                    showCalendar.toggle()
                }
                .buttonStyle(.bordered)
                .frame(width: 260, alignment: .leading)
                .popover(isPresented: $showCalendar, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        DatePicker(
                            "Installed On",
                            selection: $selectedDate,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(width: 280)

                        HStack {
                            Button("Clear") {
                                text = ""
                                showCalendar = false
                            }

                            Spacer()

                            Button("Today") {
                                selectedDate = Date()
                                text = DateFormatter.installedOnDate.string(from: selectedDate)
                                showCalendar = false
                            }

                            Button("Done") {
                                text = DateFormatter.installedOnDate.string(from: selectedDate)
                                showCalendar = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding()
                }

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear installed date")
                }
            }
        }
    }
}

// MARK: - Formatters

extension DateFormatter {
    static let inventoryDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let installedOnDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let agentStatusTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
