import AppKit
import Foundation

enum RelayTaskStatus: String, Codable {
    case queued
    case starting
    case running
    case waitingForApproval = "waiting_for_approval"
    case waitingForInput = "waiting_for_input"
    case completed
    case failed
    case canceled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled:
            true
        default:
            false
        }
    }

    var displayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").uppercased()
    }
}

enum RelayOutputKind: String, Codable {
    case user
    case assistant
    case tool
    case system
    case error
}

enum RelayInteractionKind: String, Codable {
    case approval
    case input
}

struct RelayInteractionOption: Codable, Identifiable, Hashable {
    let value: String
    let label: String
    let description: String?

    var id: String { value }
}

struct RelayInteractionQuestion: Codable, Identifiable, Hashable {
    let id: String
    let prompt: String
    let options: [RelayInteractionOption]
    let allowCustom: Bool
    let secret: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case prompt
        case options
        case allowCustom = "allow_custom"
        case secret
    }
}

struct RelayInteraction: Codable, Identifiable, Hashable {
    let id: String
    let kind: RelayInteractionKind
    let title: String
    let message: String
    let actions: [RelayInteractionOption]
    let questions: [RelayInteractionQuestion]
}

private struct RelayInteractionResponse: Encodable {
    let interactionID: String
    let action: String?
    let answers: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case interactionID = "interaction_id"
        case action
        case answers
    }
}

enum RelayCodexMode: String, CaseIterable {
    case defaultMode = "default"
    case plan

    var label: String { rawValue.uppercased() }
}

struct RelayTaskOutput: Codable, Identifiable, Hashable {
    let sequence: UInt64
    let timestampMilliseconds: UInt64
    let kind: RelayOutputKind
    let text: String

    var id: UInt64 { sequence }

    enum CodingKeys: String, CodingKey {
        case sequence
        case timestampMilliseconds = "timestamp_ms"
        case kind
        case text
    }
}

struct RelayTask: Codable, Identifiable, Hashable {
    let id: String
    let adapterID: String
    let promptPreview: String
    let title: String?
    let pendingInteraction: RelayInteraction?
    let cwd: String
    let status: RelayTaskStatus
    let createdAtMilliseconds: UInt64
    let updatedAtMilliseconds: UInt64
    let latestMessage: String?
    let sessionID: String?
    let turnCount: UInt32
    let adapterOptions: [String: String]

    var compareGroup: String? { adapterOptions["relay_group"] }
    var chainStep: Int? { adapterOptions["relay_chain_step"].flatMap(Int.init) }
    var chainAgents: [String]? {
        adapterOptions["relay_chain_agents"].map {
            $0.split(separator: ",").map(String.init)
        }
    }
    var chainNote: String? { adapterOptions["relay_chain_note"] }

    enum CodingKeys: String, CodingKey {
        case id
        case adapterID = "adapter_id"
        case promptPreview = "prompt_preview"
        case title
        case pendingInteraction = "pending_interaction"
        case cwd
        case status
        case createdAtMilliseconds = "created_at_ms"
        case updatedAtMilliseconds = "updated_at_ms"
        case latestMessage = "latest_message"
        case sessionID = "session_id"
        case turnCount = "turn_count"
        case adapterOptions = "adapter_options"
    }

    var shortID: String { String(id.prefix(8)) }
    var displayTitle: String { title ?? promptPreview }

    var updatedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAtMilliseconds) / 1_000)
    }
}

private struct RelayResponse: Decodable {
    let type: String
    let task: RelayTask?
    let tasks: [RelayTask]?
    let output: [RelayTaskOutput]?
    let truncated: Bool?
    let protocolVersion: UInt32?
    let daemonVersion: String?
    let adapters: [String]?
    let taskID: String?
    let adapterID: String?
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case task
        case tasks
        case output
        case truncated
        case protocolVersion = "protocol_version"
        case daemonVersion = "daemon_version"
        case adapters
        case taskID = "task_id"
        case adapterID = "adapter_id"
        case code
        case message
    }
}

enum DaemonState: Equatable {
    case connecting
    case online
    case offline

    var label: String {
        switch self {
        case .connecting: "CONNECTING"
        case .online: "ONLINE"
        case .offline: "OFFLINE"
        }
    }
}

enum DaemonLaunchConfiguration {
    static func executablePath(fromPropertyList data: Data) -> String? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
            let arguments = propertyList["ProgramArguments"] as? [String],
            let executable = arguments.first,
            !executable.isEmpty else {
            return nil
        }
        return executable
    }

    static func requiresReplacement(
        runningVersion: String,
        bundledVersion: String,
        installedExecutable: String?,
        bundledExecutable: String
    ) -> Bool {
        if runningVersion != bundledVersion {
            return true
        }
        guard let installedExecutable else { return false }
        return normalized(installedExecutable) != normalized(bundledExecutable)
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

struct RelayProjectHistory {
    static let defaultsKey = "recentWorkingDirectories"
    static let limit = 6

    static func load(
        currentDirectory: String,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [String] {
        let saved = defaults.stringArray(forKey: defaultsKey) ?? []
        var result: [String] = []
        for path in [currentDirectory] + saved {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !result.contains(normalized) else {
                continue
            }
            result.append(normalized)
            if result.count == limit {
                break
            }
        }
        return result
    }

    static func recording(_ path: String, in existing: [String]) -> [String] {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        var result = [normalized]
        for candidate in existing {
            let value = URL(fileURLWithPath: candidate).standardizedFileURL.path
            if !result.contains(value) {
                result.append(value)
            }
            if result.count == limit {
                break
            }
        }
        return result
    }
}

private enum RelayClientError: LocalizedError {
    case missingResource(String)
    case commandFailed(String)
    case invalidResponse(String)
    case daemonUnavailable
    case invalidDirectory(String)
    case unavailableAgent(String)
    case adapterImportRejected(String)
    case legacyDaemonHasActiveTasks(Int)
    case legacyDaemonUnavailable

    var errorDescription: String? {
        switch self {
        case let .missingResource(name):
            "Missing bundled resource: \(name)"
        case let .commandFailed(message):
            message
        case let .invalidResponse(message):
            "Invalid daemon response: \(message)"
        case .daemonUnavailable:
            "The local daemon did not become ready."
        case let .invalidDirectory(path):
            "Working directory does not exist: \(path)"
        case let .unavailableAgent(name):
            "\(name) CLI was not found on this Mac."
        case let .adapterImportRejected(reason):
            "Adapter import rejected: \(reason)"
        case let .legacyDaemonHasActiveTasks(count):
            "Relay v0.12 still has \(count) active task(s). Reopen this app after they finish so the daemon can be upgraded safely."
        case .legacyDaemonUnavailable:
            "Relay v0.12 daemon is loaded but its task state cannot be read. It was left running to protect existing work."
        }
    }
}

@MainActor
final class RelayService: ObservableObject {
    @Published private(set) var agents: [RelayAgent]
    @Published private(set) var personas: [RelayPersona] = RelayPersonaStore.load()
    @Published private(set) var taskHooks: [RelayTaskHook] = RelayTaskHookStore.load()
    private let taskHookRunner = RelayTaskHookRunner()
    @Published private(set) var tasks: [RelayTask] = []
    @Published private(set) var output: [RelayTaskOutput] = []
    @Published private(set) var outputTruncated = false
    @Published private(set) var daemonState: DaemonState = .connecting
    @Published private(set) var daemonVersion: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var respondingInteractionID: String?
    @Published private(set) var mixModels: [String]
    @Published private(set) var mixEfforts: [String]
    @Published var selectedTaskID: String?
    @Published var selectedAgentID = "codex"
    @Published var workingDirectory: String
    @Published private(set) var defaultWorkingDirectory: String
    @Published private(set) var recentWorkingDirectories: [String]
    @Published var mixModel: String
    @Published var mixEffort: String
    @Published var codexMode: RelayCodexMode
    @Published private(set) var language: RelayLanguage
    @Published var errorMessage: String?
    @Published private(set) var compareMode = false
    @Published private(set) var compareSelection: Set<String> = []
    @Published private(set) var groupOutputs: [String: [RelayTaskOutput]] = [:]
    @Published private(set) var agentOptionValues: [String: [String: String]] = [:]
    @Published private(set) var chainMode = false
    @Published private(set) var chainSequence: [String] = []
    @Published var chainNote = ""
    @Published private(set) var notificationsEnabled =
        UserDefaults.standard.object(forKey: "notificationsEnabled") == nil
            || UserDefaults.standard.bool(forKey: "notificationsEnabled")
    @Published private(set) var quickBarEnabled =
        UserDefaults.standard.object(forKey: "quickBarEnabled") == nil
            || UserDefaults.standard.bool(forKey: "quickBarEnabled")
    @Published private(set) var chainTemplates = RelayChainTemplate.load()
    @Published private(set) var paneTaskIDs: [String] = []
    var onTaskEvents: (([RelayNotificationEvent]) -> Void)?
    private var notificationBaseline: [String: RelayTaskStatus]?

    private var monitoringTask: Task<Void, Never>?
    private var isComposingNewThread = false
    private var outputSyncKey: String?
    private var outputSyncSkips = 0
    private var groupSyncKeys: [String: String] = [:]
    private var groupSyncSkips: [String: Int] = [:]
    private let mixEffortsByModel: [String: [String]]
    private let applicationDirectory: URL
    private let adapterDirectory: URL
    private let bundledAdapterDirectory: URL?
    private let genericAdapterURL: URL?
    private let acpAdapterURL: URL?
    private let homeDirectory: URL
    private let runtimeDirectory: URL
    private let socketURL: URL
    private static let daemonLabel = RelayProtocol.daemonLabel
    private static let legacyDaemonLabel = RelayProtocol.legacyDaemonLabel

    private var daemonPlistURL: URL {
        runtimeDirectory.appendingPathComponent(RelayProtocol.daemonPropertyListName)
    }

    var daemonLogURL: URL {
        runtimeDirectory.appendingPathComponent("relayd.log")
    }

    func openDaemonLog() {
        let path = daemonLogURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        NSWorkspace.shared.open(daemonLogURL)
    }

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        applicationDirectory = support.appendingPathComponent("Relay", isDirectory: true)
        adapterDirectory = applicationDirectory.appendingPathComponent("adapters", isDirectory: true)
        bundledAdapterDirectory = Bundle.main.resourceURL?
            .appendingPathComponent("adapters", isDirectory: true)
        genericAdapterURL = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("generic-adapter")
        acpAdapterURL = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("acp-adapter")
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        runtimeDirectory = applicationDirectory.appendingPathComponent("runtime", isDirectory: true)
        socketURL = runtimeDirectory.appendingPathComponent(RelayProtocol.socketName)
        let home = homeDirectory
        let savedDirectory = UserDefaults.standard.string(forKey: "workingDirectory")
        let savedCandidate = URL(
            fileURLWithPath: savedDirectory ?? home.path
        ).standardizedFileURL.path
        var savedCandidateIsDirectory = ObjCBool(false)
        let initialDirectory = FileManager.default.fileExists(
            atPath: savedCandidate,
            isDirectory: &savedCandidateIsDirectory
        ) && savedCandidateIsDirectory.boolValue ? savedCandidate : home.path
        workingDirectory = initialDirectory
        defaultWorkingDirectory = initialDirectory
        let initialRecentDirectories = RelayProjectHistory.load(
            currentDirectory: initialDirectory
        )
        recentWorkingDirectories = initialRecentDirectories
        UserDefaults.standard.set(
            initialRecentDirectories,
            forKey: RelayProjectHistory.defaultsKey
        )
        let catalog = Self.loadCodexModels(home: home)
        mixModels = catalog.models
        mixEffortsByModel = catalog.efforts
        let savedModel = UserDefaults.standard.string(forKey: "mixModel")
        let initialMixModel = savedModel.flatMap { catalog.models.contains($0) ? $0 : nil }
            ?? (catalog.models.contains("gpt-5.6-sol") ? "gpt-5.6-sol" : "auto")
        let initialMixEfforts = catalog.efforts[initialMixModel] ?? Self.allMixEfforts
        let savedEffort = UserDefaults.standard.string(forKey: "mixEffort")
        let initialMixEffort = savedEffort.flatMap { initialMixEfforts.contains($0) ? $0 : nil }
            ?? (initialMixEfforts.contains("max") ? "max" : initialMixEfforts.last ?? "high")
        mixModel = initialMixModel
        mixEfforts = initialMixEfforts
        mixEffort = initialMixEffort
        codexMode = RelayCodexMode(
            rawValue: UserDefaults.standard.string(forKey: "codexMode") ?? "default"
        ) ?? .defaultMode
        language = RelayLanguage.load()
        agents = AdapterCatalog.load(
            bundledDirectory: bundledAdapterDirectory,
            userDirectory: adapterDirectory,
            home: home,
            genericAdapter: genericAdapterURL,
            acpAdapter: acpAdapterURL,
            codexModels: catalog.models,
            claudeModels: RelayClaudeModels.discover(
                binaryURL: RelayClaudeModels.resolveBinary(home: home),
                accountConfigURL: home.appendingPathComponent(".claude.json")
            )
        )
        if !agents.contains(where: { $0.id == selectedAgentID }) {
            selectedAgentID = agents.first?.id ?? ""
        }
        loadAgentOptionValues()
    }

    var selectedTask: RelayTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    var selectedAgent: RelayAgent? {
        agents.first { $0.id == selectedAgentID }
    }

    var canSubmit: Bool {
        guard daemonState == .online else { return false }
        if chainMode {
            guard let first = chainSequence.first,
                  agents.first(where: { $0.id == first })?.isAvailable == true else { return false }
        } else if compareMode {
            guard compareSelection.contains(where: { id in
                agents.first(where: { $0.id == id })?.isAvailable == true
            }) else { return false }
        } else if selectedAgent?.isAvailable != true {
            return false
        }
        return selectedTask?.status.isTerminal != false
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            await self?.runMonitoringLoop()
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func runMonitoringLoop() async {
        while !Task.isCancelled {
            if daemonState != .online {
                await connect()
            }
            if daemonState == .online {
                do {
                    try await watchTaskUpdates()
                } catch is CancellationError {
                    return
                } catch {
                    daemonState = .offline
                }
            }
            if !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func reconnect() async {
        daemonState = .connecting
        await connect()
    }

    func refreshAll() async {
        reloadAdapters()
        await synchronizeAdapters()
        await refreshTasks(showErrors: true)
        await loadAgentVersions()
    }

    var userAdapterDirectory: URL { adapterDirectory }

    func isUserAdapter(_ agent: RelayAgent) -> Bool {
        AdapterCatalog.isUserManifest(agent.manifestURL, userDirectory: adapterDirectory)
    }

    func lineCLIConfiguration(for agent: RelayAgent) -> LineCLIConfiguration? {
        guard isUserAdapter(agent) else { return nil }
        return AdapterCatalog.lineCLIConfiguration(at: agent.manifestURL)
    }

    func importAdapter(from source: URL) async {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                source.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try prepareRuntimeDirectory()
            let candidate = AdapterCatalog.loadManifest(
                at: source,
                home: homeDirectory,
                genericAdapter: genericAdapterURL,
                acpAdapter: acpAdapterURL
            )
            if case let .invalid(reason) = candidate.health {
                throw RelayClientError.adapterImportRejected(reason)
            }
            try await validateGenericManifest(candidate)
            let fileManager = FileManager.default
            let destination = adapterDirectory.appendingPathComponent(source.lastPathComponent)
            if let conflict = AdapterCatalog.importBlockReason(
                candidateID: candidate.id,
                destination: destination,
                agents: agents
            ) {
                throw RelayClientError.adapterImportRejected(conflict)
            }
            if fileManager.fileExists(atPath: destination.path) {
                let existing = AdapterCatalog.loadManifest(
                    at: destination,
                    home: homeDirectory,
                    genericAdapter: genericAdapterURL,
                    acpAdapter: acpAdapterURL
                )
                if !existing.id.hasPrefix("invalid:"), existing.id != candidate.id {
                    throw RelayClientError.adapterImportRejected(
                        "\(destination.lastPathComponent) already provides adapter \(existing.id); rename the imported file"
                    )
                }
            }
            let probe = adapterDirectory.appendingPathComponent(".import-\(UUID().uuidString).json")
            try fileManager.copyItem(at: source, to: probe)
            defer { try? fileManager.removeItem(at: probe) }
            let relocated = AdapterCatalog.loadManifest(
                at: probe,
                home: homeDirectory,
                genericAdapter: genericAdapterURL,
                acpAdapter: acpAdapterURL
            )
            if relocated.health != candidate.health,
               let reason = relocated.health.reason {
                throw RelayClientError.adapterImportRejected(
                    "\(reason) — the manifest references files relative to its source directory; move them into the adapter directory first"
                )
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            errorMessage = nil
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createLineCLIAdapter(
        id rawID: String,
        name: String,
        executablePath: String,
        arguments: [String]
    ) async -> Bool {
        do {
            try prepareRuntimeDirectory()
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let executable = try validatedLineCLIExecutable(executablePath)
            let data = try AdapterCatalog.genericManifestData(
                id: id,
                name: name,
                executablePath: executable.path,
                arguments: arguments
            )
            let destination = adapterDirectory.appendingPathComponent("\(id).json")
            if let conflict = AdapterCatalog.importBlockReason(
                candidateID: id,
                destination: destination,
                agents: agents
            ) {
                throw RelayClientError.adapterImportRejected(conflict)
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw RelayClientError.adapterImportRejected(
                    "\(destination.lastPathComponent) already exists"
                )
            }

            try data.write(to: destination, options: .atomic)
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
                let installed = AdapterCatalog.loadManifest(
                    at: destination,
                    home: homeDirectory,
                    genericAdapter: genericAdapterURL,
                    acpAdapter: acpAdapterURL
                )
                guard installed.id == id, installed.health == .checking else {
                    throw RelayClientError.adapterImportRejected(
                        installed.health.reason ?? "Generated manifest could not be loaded"
                    )
                }
                try await validateGenericManifest(installed)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }

            errorMessage = nil
            await refreshAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateLineCLIAdapter(
        _ agent: RelayAgent,
        name: String,
        executablePath: String,
        arguments: [String]
    ) async -> Bool {
        do {
            guard isUserAdapter(agent),
                  let configuration = AdapterCatalog.lineCLIConfiguration(at: agent.manifestURL),
                  configuration.id == agent.id else {
                throw RelayClientError.adapterImportRejected(
                    "Only simple line CLI adapters created by Relay can be edited here"
                )
            }
            let executable = try validatedLineCLIExecutable(executablePath)
            let data = try AdapterCatalog.genericManifestData(
                id: configuration.id,
                name: name,
                executablePath: executable.path,
                arguments: arguments
            )
            let original = try Data(contentsOf: agent.manifestURL)
            try data.write(to: agent.manifestURL, options: .atomic)
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: agent.manifestURL.path
                )
                let installed = AdapterCatalog.loadManifest(
                    at: agent.manifestURL,
                    home: homeDirectory,
                    genericAdapter: genericAdapterURL,
                    acpAdapter: acpAdapterURL
                )
                guard installed.id == configuration.id, installed.health == .checking else {
                    throw RelayClientError.adapterImportRejected(
                        installed.health.reason ?? "Updated manifest could not be loaded"
                    )
                }
                try await validateGenericManifest(installed)
            } catch {
                try? original.write(to: agent.manifestURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: agent.manifestURL.path
                )
                throw error
            }

            errorMessage = nil
            await refreshAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteUserAdapter(_ agent: RelayAgent) async {
        guard isUserAdapter(agent) else { return }
        do {
            let response = try await request(["unregister-adapter", "--id", agent.id])
            guard response.type == "adapter_unregistered",
                  response.adapterID == agent.id else {
                throw RelayClientError.invalidResponse(response.type)
            }
            do {
                try FileManager.default.removeItem(at: agent.manifestURL)
            } catch {
                await synchronizeAdapters()
                throw error
            }
            errorMessage = nil
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validatedLineCLIExecutable(_ rawPath: String) throws -> URL {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw RelayClientError.adapterImportRejected(
                "CLI executable must use an absolute path"
            )
        }
        let executable = URL(fileURLWithPath: path).standardizedFileURL
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RelayClientError.adapterImportRejected(
                "CLI executable was not found or is not executable: \(executable.path)"
            )
        }
        return executable
    }

    func selectAgent(_ id: String) {
        guard agents.contains(where: { $0.id == id }) else { return }
        selectedAgentID = id
        selectedTaskID = nil
        workingDirectory = defaultWorkingDirectory
        isComposingNewThread = true
        output = []
        outputTruncated = false
        errorMessage = nil
        restorePersistedAdapterSettings()
    }

    func selectTask(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        selectedTaskID = id
        isComposingNewThread = false
        selectedAgentID = task.adapterID
        workingDirectory = task.cwd
        applyAdapterSettings(from: task)
        output = []
        outputTruncated = false
        Task { await refreshSelectedOutput(showErrors: true, force: true) }
    }

    func startNewThread() {
        selectedTaskID = nil
        workingDirectory = defaultWorkingDirectory
        selectFallbackAgentIfNeeded()
        isComposingNewThread = true
        output = []
        outputTruncated = false
        errorMessage = nil
        restorePersistedAdapterSettings()
    }

    func toggleCompareMode() {
        compareMode.toggle()
        if compareMode {
            chainMode = false
            chainSequence = []
            compareSelection = selectedAgentID.isEmpty ? [] : [selectedAgentID]
            startNewThread()
        } else {
            compareSelection = []
        }
    }

    func toggleChainMode() {
        chainMode.toggle()
        if chainMode {
            compareMode = false
            compareSelection = []
            chainSequence = selectedAgentID.isEmpty ? [] : [selectedAgentID]
            startNewThread()
        } else {
            chainSequence = []
        }
    }

    func appendChainAgent(_ id: String) {
        guard chainMode,
              chainSequence.count < 4,
              agents.contains(where: { $0.id == id }) else { return }
        chainSequence.append(id)
    }

    func clearChainSequence() {
        chainSequence = []
    }

    func removeLastChainAgent() {
        guard !chainSequence.isEmpty else { return }
        chainSequence.removeLast()
    }

    func submitChain(prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        guard chainSequence.count >= 2 else {
            errorMessage = "Add at least two chain steps."
            return
        }
        let missing = chainSequence.first { id in
            agents.first(where: { $0.id == id })?.isAvailable != true
        }
        if let missing {
            errorMessage = RelayClientError.unavailableAgent(missing).localizedDescription
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            errorMessage = RelayClientError.invalidDirectory(workingDirectory).localizedDescription
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }

        let chain = UUID().uuidString.lowercased()
        var arguments = [
            "start-chain",
            "--id", chain,
            "--stdin",
            "--cwd", workingDirectory,
        ]
        for (index, adapterID) in chainSequence.enumerated() {
            arguments += ["--step", adapterID]
            for (key, value) in adapterOptions(for: adapterID).sorted(by: { $0.key < $1.key }) {
                arguments += ["--step-option", "\(index + 1):\(key)=\(value)"]
            }
        }
        let note = sanitizedChainNote
        if !note.isEmpty {
            arguments += ["--note", note]
        }
        do {
            let response = try await request(arguments, input: Data(trimmed.utf8))
            guard response.type == "task", let task = response.task else {
                throw RelayClientError.invalidResponse(response.type)
            }
            selectedTaskID = task.id
            isComposingNewThread = false
            chainMode = false
            chainSequence = []
            chainNote = ""
            errorMessage = nil
            await refreshTasks(showErrors: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var sanitizedChainNote: String {
        let flattened = chainNote
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let sanitized = flattened
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        return String(sanitized.prefix(200))
    }

    func handoff(to agentID: String, instruction: String) async {
        guard let source = selectedTask else { return }
        await relayContext(
            from: source,
            to: agentID,
            body: { output in
                let transcript = ThreadCatalog.transcriptText(output)
                let extra = instruction.isEmpty ? "请基于以上上下文继续处理。" : instruction
                return "以下是与 \(source.adapterID) 的既有对话上下文：\n\n\(transcript)\n\n\(extra)"
            },
            provenanceOption: "relay_handoff_from",
            titlePrefix: "⇄"
        )
    }

    func promoteCompareMember(_ taskID: String, to agentID: String) async {
        guard let source = tasks.first(where: { $0.id == taskID }) else { return }
        await relayContext(
            from: source,
            to: agentID,
            body: { output in
                let answer = ThreadCatalog.lastTurnAnswer(output)
                return "以下是多智能体对比中被选中的最佳答案（来自 \(source.adapterID)），请基于它继续：\n\n\(answer)"
            },
            provenanceOption: "relay_pick_from",
            titlePrefix: "★"
        )
    }

    private func relayContext(
        from source: RelayTask,
        to agentID: String,
        body: ([RelayTaskOutput]) -> String,
        provenanceOption: String,
        titlePrefix: String
    ) async {
        guard !isSubmitting else { return }
        guard source.status.isTerminal else {
            errorMessage = "The selected task is still running."
            return
        }
        guard let target = agents.first(where: { $0.id == agentID }),
              target.isAvailable else {
            errorMessage = RelayClientError.unavailableAgent(agentID).localizedDescription
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            var sourceOutput = source.id == selectedTaskID ? output : []
            if sourceOutput.isEmpty {
                sourceOutput = groupOutputs[source.id] ?? []
            }
            if sourceOutput.isEmpty {
                let response = try await request(["output", source.id])
                guard response.type == "task_output", let received = response.output else {
                    throw RelayClientError.invalidResponse(response.type)
                }
                sourceOutput = received
            }
            let prompt = body(sourceOutput)
            let response = try await request([
                "start",
                "--adapter", target.id,
                "--stdin",
                "--cwd", source.cwd,
                "--option", "\(provenanceOption)=\(source.shortID)",
            ] + adapterOptionArguments(for: target.id), input: Data(prompt.utf8))
            guard response.type == "task", let task = response.task else {
                throw RelayClientError.invalidResponse(response.type)
            }
            _ = try? await request([
                "rename", task.id,
                "--title", "\(titlePrefix) \(String(source.displayTitle.prefix(48)))",
            ])
            selectedTaskID = task.id
            isComposingNewThread = false
            errorMessage = nil
            await refreshTasks(showErrors: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleCompareAgent(_ id: String) {
        guard compareMode, agents.contains(where: { $0.id == id }) else { return }
        if compareSelection.contains(id) {
            compareSelection.remove(id)
        } else {
            compareSelection.insert(id)
        }
    }

    func submitCompare(prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        let members = agents.filter { compareSelection.contains($0.id) }
        guard members.count >= 2 else {
            errorMessage = "Select at least two agents to compare."
            return
        }
        if let unavailable = members.first(where: { !$0.isAvailable }) {
            errorMessage = RelayClientError.unavailableAgent(unavailable.name).localizedDescription
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            errorMessage = RelayClientError.invalidDirectory(workingDirectory).localizedDescription
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }

        let group = UUID().uuidString.lowercased()
        let promptData = Data(trimmed.utf8)
        var firstMemberTaskID: String?
        do {
            for member in members.sorted(by: { $0.id < $1.id }) {
                let response = try await request([
                    "start",
                    "--adapter", member.id,
                    "--stdin",
                    "--cwd", workingDirectory,
                    "--option", "relay_group=\(group)",
                ] + adapterOptionArguments(for: member.id), input: promptData)
                guard response.type == "task", let task = response.task else {
                    throw RelayClientError.invalidResponse(response.type)
                }
                if firstMemberTaskID == nil {
                    firstMemberTaskID = task.id
                }
            }
            selectedTaskID = firstMemberTaskID
            isComposingNewThread = false
            compareMode = false
            compareSelection = []
            errorMessage = nil
            await refreshTasks(showErrors: true)
        } catch {
            errorMessage = error.localizedDescription
            if firstMemberTaskID != nil {
                selectedTaskID = firstMemberTaskID
                isComposingNewThread = false
                compareMode = false
                compareSelection = []
                await refreshTasks(showErrors: false)
            }
        }
    }

    private func restorePersistedAdapterSettings() {
        codexMode = RelayCodexMode(
            rawValue: UserDefaults.standard.string(forKey: "codexMode") ?? "default"
        ) ?? .defaultMode
        if let model = UserDefaults.standard.string(forKey: "mixModel"),
           mixModels.contains(model) {
            mixModel = model
            mixEfforts = mixEffortsByModel[model] ?? Self.allMixEfforts
        }
        if let effort = UserDefaults.standard.string(forKey: "mixEffort"),
           mixEfforts.contains(effort) {
            mixEffort = effort
        }
    }

    func setWorkingDirectory(_ path: String) {
        workingDirectory = path
        defaultWorkingDirectory = path
        UserDefaults.standard.set(path, forKey: "workingDirectory")
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
    }

    func saveChainTemplate(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, chainSequence.count >= 2 else { return }
        var templates = chainTemplates.filter { $0.name != trimmed }
        templates.append(RelayChainTemplate(
            name: String(trimmed.prefix(40)),
            agents: chainSequence,
            note: chainNote
        ))
        chainTemplates = templates.sorted { $0.name < $1.name }
        RelayChainTemplate.store(chainTemplates)
    }

    func applyChainTemplate(_ template: RelayChainTemplate) {
        let missing = template.agents.filter { id in
            agents.first(where: { $0.id == id })?.isAvailable != true
        }
        guard missing.isEmpty else {
            errorMessage = RelayClientError.unavailableAgent(
                missing.joined(separator: ", ")
            ).localizedDescription
            return
        }
        if !chainMode {
            toggleChainMode()
        }
        chainSequence = template.agents
        chainNote = template.note
    }

    func deleteChainTemplate(_ template: RelayChainTemplate) {
        chainTemplates.removeAll { $0.name == template.name }
        RelayChainTemplate.store(chainTemplates)
    }

    func setQuickBarEnabled(_ enabled: Bool) {
        quickBarEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "quickBarEnabled")
    }

    func quickSubmit(agentID: String, prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let agent = agents.first(where: { $0.id == agentID }),
              agent.isAvailable else {
            errorMessage = RelayClientError.unavailableAgent(agentID).localizedDescription
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: defaultWorkingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            errorMessage = RelayClientError.invalidDirectory(defaultWorkingDirectory)
                .localizedDescription
            return
        }
        do {
            let response = try await request([
                "start",
                "--adapter", agent.id,
                "--stdin",
                "--cwd", defaultWorkingDirectory,
            ] + adapterOptionArguments(for: agent.id), input: Data(trimmed.utf8))
            guard response.type == "task", let task = response.task else {
                throw RelayClientError.invalidResponse(response.type)
            }
            selectedTaskID = task.id
            isComposingNewThread = false
            await refreshTasks(showErrors: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDefaultWorkingDirectory(_ path: String) {
        defaultWorkingDirectory = path
        if selectedTaskID == nil {
            workingDirectory = path
        }
        UserDefaults.standard.set(path, forKey: "workingDirectory")
    }

    func activateProjectDirectory(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = RelayClientError.invalidDirectory(normalized).localizedDescription
            return
        }
        setDefaultWorkingDirectory(normalized)
        recentWorkingDirectories = RelayProjectHistory.recording(
            normalized,
            in: recentWorkingDirectories
        )
        UserDefaults.standard.set(
            recentWorkingDirectories,
            forKey: RelayProjectHistory.defaultsKey
        )
    }

    func setMixModel(_ model: String, persist: Bool = true) {
        guard mixModels.contains(model) else { return }
        mixModel = model
        mixEfforts = mixEffortsByModel[model] ?? Self.allMixEfforts
        if !mixEfforts.contains(mixEffort) {
            mixEffort = mixEfforts.contains("max") ? "max" : mixEfforts.last ?? "high"
            if persist {
                UserDefaults.standard.set(mixEffort, forKey: "mixEffort")
            }
        }
        if persist {
            UserDefaults.standard.set(model, forKey: "mixModel")
        }
    }

    func setMixEffort(_ effort: String, persist: Bool = true) {
        guard mixEfforts.contains(effort) else {
            return
        }
        mixEffort = effort
        if persist {
            UserDefaults.standard.set(effort, forKey: "mixEffort")
        }
    }

    func setCodexMode(_ mode: RelayCodexMode, persist: Bool = true) {
        codexMode = mode
        if persist {
            UserDefaults.standard.set(mode.rawValue, forKey: "codexMode")
        }
    }

    func setLanguage(_ language: RelayLanguage) {
        self.language = language
        language.save()
    }

    func refreshTasks(showErrors: Bool = true) async {
        do {
            let response = try await request(["list"])
            guard response.type == "tasks", let receivedTasks = response.tasks else {
                throw RelayClientError.invalidResponse(response.type)
            }
            await applyTaskList(receivedTasks, showErrors: showErrors)
        } catch {
            daemonState = await canPing() ? .online : .offline
            if showErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyTaskList(_ receivedTasks: [RelayTask], showErrors: Bool) async {
        tasks = receivedTasks.sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
        let events = RelayNotificationPlanner.events(
            previous: notificationBaseline,
            current: tasks
        )
        notificationBaseline = RelayNotificationPlanner.baseline(tasks)
        if !events.isEmpty {
            onTaskEvents?(events)
            taskHookRunner.process(events: events, hooks: taskHooks)
        }
        if let selectedTaskID, !tasks.contains(where: { $0.id == selectedTaskID }) {
            self.selectedTaskID = nil
            output = []
        }
        if selectedTaskID == nil, !isComposingNewThread, let first = tasks.first {
            selectedTaskID = first.id
            selectedAgentID = first.adapterID
            workingDirectory = first.cwd
            applyAdapterSettings(from: first)
        }
        if selectedTaskID == nil {
            selectFallbackAgentIfNeeded()
        }
        paneTaskIDs = paneTaskIDs.filter { id in tasks.contains { $0.id == id } }
        var retained = Set(paneTaskIDs).union(pinnedOutputTaskIDs)
        if let group = selectedTask?.compareGroup {
            for member in tasks where member.compareGroup == group {
                retained.insert(member.id)
            }
        }
        for key in groupOutputs.keys where !retained.contains(key) {
            groupOutputs.removeValue(forKey: key)
            groupSyncKeys.removeValue(forKey: key)
            groupSyncSkips.removeValue(forKey: key)
        }
        for paneID in paneTaskIDs {
            await fetchOutputIfStale(taskID: paneID, showErrors: false)
        }
        if selectedTask?.compareGroup != nil {
            await refreshGroupOutputs(showErrors: showErrors)
        } else {
            await refreshSelectedOutput(showErrors: showErrors)
        }
        await autoApplyApprovalRules()
        daemonState = .online
        if showErrors {
            errorMessage = nil
        }
    }

    func submit(prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        guard let agent = selectedAgent, agent.isAvailable else {
            errorMessage = RelayClientError.unavailableAgent(selectedAgent?.name ?? selectedAgentID).localizedDescription
            return
        }
        guard selectedTask?.status.isTerminal != false else {
            errorMessage = "The selected task is still running."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let response: RelayResponse
            let optionArguments = adapterOptionArguments(for: agent.id)
            let promptData = Data(trimmed.utf8)
            if let task = selectedTask, task.sessionID != nil {
                response = try await request(
                    ["continue", task.id, "--stdin"] + optionArguments,
                    input: promptData
                )
            } else {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: workingDirectory,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw RelayClientError.invalidDirectory(workingDirectory)
                }
                response = try await request([
                    "start",
                    "--adapter", agent.id,
                    "--stdin",
                    "--cwd", workingDirectory,
                ] + optionArguments, input: promptData)
            }
            guard response.type == "task", let task = response.task else {
                throw RelayClientError.invalidResponse(response.type)
            }
            selectedTaskID = task.id
            isComposingNewThread = false
            errorMessage = nil
            await refreshTasks(showErrors: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelSelectedTask() async {
        guard let selectedTask, !selectedTask.status.isTerminal else { return }
        do {
            let response = try await request(["cancel", selectedTask.id])
            guard response.type == "task" else {
                throw RelayClientError.invalidResponse(response.type)
            }
            errorMessage = nil
            await refreshTasks(showErrors: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTask(_ id: String) async {
        do {
            let response = try await request(["delete", id])
            guard response.type == "task_deleted", response.taskID == id else {
                throw RelayClientError.invalidResponse(response.type)
            }
            if selectedTaskID == id {
                startNewThread()
            }
            await refreshTasks(showErrors: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameTask(_ id: String, title: String) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "Thread title must not be empty."
            return false
        }
        do {
            let response = try await request(["rename", id, "--title", title])
            guard response.type == "task", response.task?.id == id else {
                throw RelayClientError.invalidResponse(response.type)
            }
            errorMessage = nil
            await refreshTasks(showErrors: true)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func respondToInteraction(
        _ interaction: RelayInteraction,
        action: String? = nil,
        answers: [String: [String]] = [:]
    ) async {
        guard let task = selectedTask else { return }
        await respondToInteraction(
            taskID: task.id,
            interaction: interaction,
            action: action,
            answers: answers
        )
    }

    func respondToInteraction(
        taskID: String,
        interaction: RelayInteraction,
        action: String? = nil,
        answers: [String: [String]] = [:]
    ) async {
        guard let task = tasks.first(where: { $0.id == taskID }),
              task.pendingInteraction?.id == interaction.id,
              respondingInteractionID == nil else { return }
        respondingInteractionID = interaction.id
        defer { respondingInteractionID = nil }
        do {
            let payload = try JSONEncoder().encode(RelayInteractionResponse(
                interactionID: interaction.id,
                action: action,
                answers: answers
            ))
            let response = try await request(["respond", task.id, "--stdin"], input: payload)
            guard response.type == "task", response.task?.id == task.id else {
                throw RelayClientError.invalidResponse(response.type)
            }
            errorMessage = nil
            await refreshTasks(showErrors: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func connect() async {
        do {
            try prepareRuntimeDirectory()
            reloadAdapters()
            if await canPing() {
                try await replaceCurrentDaemonIfIdle()
            } else {
                try await prepareLegacyDaemonForUpgrade()
                try await launchDaemon(replacingExistingJob: false)
                var connected = await waitForDaemon()
                if !connected {
                    try await launchDaemon(replacingExistingJob: true)
                    connected = await waitForDaemon()
                }
                guard connected else { throw RelayClientError.daemonUnavailable }
            }
            await synchronizeAdapters()
            daemonState = .online
            errorMessage = nil
            await refreshTasks(showErrors: true)
            await loadAgentVersions()
        } catch {
            daemonState = .offline
            errorMessage = error.localizedDescription
        }
    }

    private func replaceCurrentDaemonIfIdle() async throws {
        let bundledVersion = try await bundledDaemonVersion()
        let bundledRelayd = try bundledBinary(named: "relayd")
        let installedExecutable = (try? Data(contentsOf: daemonPlistURL)).flatMap {
            DaemonLaunchConfiguration.executablePath(fromPropertyList: $0)
        }
        guard DaemonLaunchConfiguration.requiresReplacement(
            runningVersion: daemonVersion ?? "",
            bundledVersion: bundledVersion,
            installedExecutable: installedExecutable,
            bundledExecutable: bundledRelayd.path
        ) else { return }
        let response = try await request(["list"])
        guard response.type == "tasks", let tasks = response.tasks else {
            throw RelayClientError.invalidResponse(response.type)
        }
        guard tasks.allSatisfy({ $0.status.isTerminal }) else { return }

        try await launchDaemon(replacingExistingJob: true)
        guard await waitForDaemon(), daemonVersion == bundledVersion else {
            throw RelayClientError.daemonUnavailable
        }
    }

    private func bundledDaemonVersion() async throws -> String {
        let relayd = try bundledBinary(named: "relayd")
        let data = try await runCommand(executable: relayd, arguments: ["--version"])
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = output.split(whereSeparator: { $0.isWhitespace }).last,
              version.contains(".") else {
            throw RelayClientError.invalidResponse("relayd --version: \(output)")
        }
        return String(version)
    }

    private func refreshGroupOutputs(showErrors: Bool) async {
        guard let selectedTaskID, let group = selectedTask?.compareGroup else { return }
        for member in tasks where member.compareGroup == group {
            await fetchOutputIfStale(taskID: member.id, showErrors: showErrors)
        }
        output = groupOutputs[selectedTaskID] ?? []
        outputTruncated = false
    }

    private func fetchOutputIfStale(taskID: String, showErrors: Bool) async {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        let key = "\(task.id):\(task.updatedAtMilliseconds):\(task.status.rawValue)"
        let skips = groupSyncSkips[taskID] ?? 0
        if key == groupSyncKeys[taskID], skips < 5 {
            groupSyncSkips[taskID] = skips + 1
            return
        }
        do {
            let response = try await request(["output", taskID])
            guard response.type == "task_output", let received = response.output else {
                throw RelayClientError.invalidResponse(response.type)
            }
            groupOutputs[taskID] = received
            groupSyncKeys[taskID] = key
            groupSyncSkips[taskID] = 0
        } catch {
            if showErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    var paneTasks: [RelayTask] {
        paneTaskIDs.compactMap { id in tasks.first { $0.id == id } }
    }

    func pinSelectedThreadAsPane() {
        guard let id = selectedTaskID,
              !paneTaskIDs.contains(id),
              paneTaskIDs.count < 3 else { return }
        paneTaskIDs.append(id)
        Task { await fetchOutputIfStale(taskID: id, showErrors: false) }
    }

    func closePane(_ taskID: String) {
        paneTaskIDs.removeAll { $0 == taskID }
    }

    func continueThread(taskID: String, prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let task = tasks.first(where: { $0.id == taskID }),
              task.status.isTerminal,
              task.sessionID != nil else { return }
        do {
            let response = try await request(
                ["continue", taskID, "--stdin"] + adapterOptionArguments(for: task.adapterID),
                input: Data(trimmed.utf8)
            )
            guard response.type == "task", response.task != nil else {
                throw RelayClientError.invalidResponse(response.type)
            }
            errorMessage = nil
            await refreshTasks(showErrors: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Dialogue primitives (background tasks, no selection changes)

    func startDialogueTask(
        agentID: String, prompt: String, optionOverrides: [String: String] = [:]
    ) async throws -> String {
        guard let agent = agents.first(where: { $0.id == agentID }),
              agent.isAvailable else {
            throw RelayClientError.unavailableAgent(agentID)
        }
        let cwd = RelayTerminalLauncher.resolvedWorkingDirectory(defaultWorkingDirectory)
        let response = try await request([
            "start", "--adapter", agent.id, "--stdin", "--cwd", cwd,
        ] + adapterOptionArguments(for: agent.id, overrides: optionOverrides),
        input: Data(prompt.utf8))
        guard response.type == "task", let task = response.task else {
            throw RelayClientError.invalidResponse(response.type)
        }
        await refreshTasks(showErrors: false)
        return task.id
    }

    func continueDialogueTask(
        taskID: String, prompt: String, optionOverrides: [String: String] = [:]
    ) async throws {
        guard let task = tasks.first(where: { $0.id == taskID }),
              task.status.isTerminal,
              task.sessionID != nil else {
            throw RelayClientError.invalidResponse("dialogue_thread_not_resumable")
        }
        let response = try await request(
            ["continue", taskID, "--stdin"]
                + adapterOptionArguments(for: task.adapterID, overrides: optionOverrides),
            input: Data(prompt.utf8)
        )
        guard response.type == "task", response.task != nil else {
            throw RelayClientError.invalidResponse(response.type)
        }
        await refreshTasks(showErrors: false)
    }

    func taskSnapshot(_ id: String) -> RelayTask? {
        tasks.first { $0.id == id }
    }

    func outputItems(taskID: String) async -> [RelayTaskOutput] {
        guard let response = try? await request(["output", taskID]),
              response.type == "task_output",
              let received = response.output else {
            return []
        }
        return received
    }

    func cancelBackgroundTask(_ id: String) async {
        guard let task = tasks.first(where: { $0.id == id }),
              !task.status.isTerminal else { return }
        _ = try? await request(["cancel", id])
        await refreshTasks(showErrors: false)
    }

    /// User-created auto-approval rules (explicit, visible, deletable).
    @Published private(set) var approvalRules: [RelayApprovalRule] = RelayApprovalRules.load()
    /// task.id + interaction.id pairs already auto-responded (retry guard).
    private var autoRespondedInteractionKeys: Set<String> = []

    /// Saves a rule derived from this interaction, then answers it.
    func addApprovalRule(
        taskID: String,
        interaction: RelayInteraction,
        action: RelayInteractionOption
    ) async {
        guard let line = RelayApprovalRules.commandLine(from: interaction),
              let task = tasks.first(where: { $0.id == taskID }) else { return }
        let prefix = RelayApprovalRules.prefix(of: line)
        let rule = RelayApprovalRule(
            adapterID: task.adapterID,
            commandPrefix: prefix,
            actionValue: action.value,
            actionLabel: action.label,
            createdAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        if !approvalRules.contains(where: {
            $0.adapterID == rule.adapterID
                && $0.commandPrefix == rule.commandPrefix
                && $0.actionValue == rule.actionValue
        }) {
            approvalRules.append(rule)
            RelayApprovalRules.store(approvalRules)
        }
        await respondToInteraction(
            taskID: taskID, interaction: interaction, action: action.value
        )
    }

    func removeApprovalRule(_ id: UUID) {
        approvalRules.removeAll { $0.id == id }
        RelayApprovalRules.store(approvalRules)
    }

    /// Applies stored rules to newly arrived approvals (one per frame).
    private func autoApplyApprovalRules() async {
        guard respondingInteractionID == nil, !approvalRules.isEmpty else { return }
        for task in tasks {
            guard let interaction = task.pendingInteraction else { continue }
            let key = "\(task.id):\(interaction.id)"
            guard !autoRespondedInteractionKeys.contains(key) else { continue }
            guard let rule = approvalRules.first(where: {
                RelayApprovalRules.matches(
                    $0, adapterID: task.adapterID, interaction: interaction
                )
            }) else { continue }
            autoRespondedInteractionKeys.insert(key)
            await respondToInteraction(
                taskID: task.id, interaction: interaction, action: rule.actionValue
            )
            return
        }
    }

    /// Task IDs whose cached outputs must survive task-list pruning because a
    /// workspace window engine is watching them.
    private var pinnedOutputTaskIDs: Set<String> = []

    func pinOutputs(_ ids: [String]) {
        pinnedOutputTaskIDs.formUnion(ids)
    }

    func unpinOutputs(_ ids: [String]) {
        pinnedOutputTaskIDs.subtract(ids)
    }

    /// Sync-key cached output refresh for a window engine; results land in
    /// `groupOutputs`.
    func refreshMemberOutput(taskID: String) async {
        await fetchOutputIfStale(taskID: taskID, showErrors: false)
    }

    /// Starts a task tagged with a `relay_group`, without touching selection.
    func startGroupTask(
        agentID: String, prompt: String, group: String, cwd overrideCWD: String? = nil,
        optionOverrides: [String: String] = [:]
    ) async throws -> String {
        guard let agent = agents.first(where: { $0.id == agentID }),
              agent.isAvailable else {
            throw RelayClientError.unavailableAgent(agentID)
        }
        let cwd = RelayTerminalLauncher.resolvedWorkingDirectory(
            overrideCWD ?? defaultWorkingDirectory
        )
        let response = try await request([
            "start",
            "--adapter", agent.id,
            "--stdin",
            "--cwd", cwd,
            "--option", "relay_group=\(group)",
        ] + adapterOptionArguments(for: agent.id, overrides: optionOverrides),
        input: Data(prompt.utf8))
        guard response.type == "task", let task = response.task else {
            throw RelayClientError.invalidResponse(response.type)
        }
        await refreshTasks(showErrors: false)
        return task.id
    }

    /// Submits a daemon-scheduled chain, without touching selection.
    /// Returns the chain group ID shared by all step tasks.
    func startChainRun(
        sequence: [String], prompt: String, note: String,
        stepOverrides: [Int: [String: String]] = [:]
    ) async throws -> String {
        guard sequence.count >= 2 else {
            throw RelayClientError.invalidResponse("chain_needs_two_steps")
        }
        if let missing = sequence.first(where: { id in
            agents.first(where: { $0.id == id })?.isAvailable != true
        }) {
            throw RelayClientError.unavailableAgent(missing)
        }
        let cwd = RelayTerminalLauncher.resolvedWorkingDirectory(defaultWorkingDirectory)
        let chain = UUID().uuidString.lowercased()
        var arguments = [
            "start-chain",
            "--id", chain,
            "--stdin",
            "--cwd", cwd,
        ]
        for (index, adapterID) in sequence.enumerated() {
            arguments += ["--step", adapterID]
            let merged = adapterOptions(for: adapterID)
                .merging(stepOverrides[index + 1] ?? [:]) { _, override in override }
            for (key, value) in merged.sorted(by: { $0.key < $1.key }) {
                arguments += ["--step-option", "\(index + 1):\(key)=\(value)"]
            }
        }
        let flattenedNote = note
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedNote = String(
            flattenedNote.unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }
                .map(String.init)
                .joined()
                .prefix(200)
        )
        if !sanitizedNote.isEmpty {
            arguments += ["--note", sanitizedNote]
        }
        let response = try await request(arguments, input: Data(prompt.utf8))
        guard response.type == "task", response.task != nil else {
            throw RelayClientError.invalidResponse(response.type)
        }
        await refreshTasks(showErrors: false)
        return chain
    }

    private func refreshSelectedOutput(showErrors: Bool, force: Bool = false) async {
        guard let selectedTaskID else {
            output = []
            outputTruncated = false
            outputSyncKey = nil
            return
        }
        let key = tasks.first { $0.id == selectedTaskID }.map {
            "\($0.id):\($0.updatedAtMilliseconds):\($0.status.rawValue)"
        }
        if !force, let key, key == outputSyncKey, outputSyncSkips < 5 {
            outputSyncSkips += 1
            return
        }
        do {
            let response = try await request(["output", selectedTaskID])
            guard response.type == "task_output", let receivedOutput = response.output else {
                throw RelayClientError.invalidResponse(response.type)
            }
            output = receivedOutput
            outputTruncated = response.truncated ?? false
            outputSyncKey = key
            outputSyncSkips = 0
        } catch {
            if showErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadAgentVersions() async {
        for index in agents.indices {
            guard agents[index].version == nil,
                  let path = agents[index].versionExecutablePath,
                  !agents[index].versionArguments.isEmpty else { continue }
            let version = try? await runCommand(
                executable: URL(fileURLWithPath: path),
                arguments: agents[index].versionArguments
            )
            if let version,
               let text = String(data: version, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                agents[index].version = text
            }
        }
    }

    private func prepareRuntimeDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: applicationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: adapterDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationDirectory.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adapterDirectory.path)
    }

    private func canPing() async -> Bool {
        guard let response = try? await request(["ping"]),
              response.type == "pong",
              response.protocolVersion == RelayProtocol.current else {
            return false
        }
        daemonVersion = response.daemonVersion
        return true
    }

    private func watchTaskUpdates() async throws {
        let relayctl = try bundledBinary(named: "relayctl")
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = relayctl
        process.arguments = [
            "--socket", socketURL.path,
            "watch", "--interval-ms", "1000",
            "--parent-pid", String(getpid()),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        let errorTask = Task.detached {
            errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        do {
            try await withTaskCancellationHandler {
                for try await line in outputPipe.fileHandleForReading.bytes.lines {
                    try Task.checkCancellation()
                    let response = try JSONDecoder().decode(
                        RelayResponse.self,
                        from: Data(line.utf8)
                    )
                    guard response.type == "tasks", let receivedTasks = response.tasks else {
                        throw RelayClientError.invalidResponse(response.type)
                    }
                    await applyTaskList(receivedTasks, showErrors: false)
                }
                process.waitUntilExit()
                let errorOutput = await errorTask.value
                try Task.checkCancellation()
                guard process.terminationStatus == 0 else {
                    let message = String(data: errorOutput, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw RelayClientError.commandFailed(
                        message?.isEmpty == false
                            ? message!
                            : "watch exited with status \(process.terminationStatus)"
                    )
                }
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            _ = await errorTask.value
            throw error
        }
    }

    private func request(
        _ arguments: [String],
        input: Data? = nil,
        socket: URL? = nil
    ) async throws -> RelayResponse {
        let relayctl = try bundledBinary(named: "relayctl")
        let data = try await runCommand(
            executable: relayctl,
            arguments: ["--socket", (socket ?? socketURL).path] + arguments,
            input: input
        )
        let response = try JSONDecoder().decode(RelayResponse.self, from: data)
        if response.type == "error" {
            throw RelayClientError.commandFailed(
                [response.code, response.message].compactMap { $0 }.joined(separator: ": ")
            )
        }
        return response
    }

    private func prepareLegacyDaemonForUpgrade() async throws {
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(Self.legacyDaemonLabel)"
        guard (try? await runCommand(
            executable: launchctl,
            arguments: ["print", service]
        )) != nil else { return }

        let legacySocket = runtimeDirectory.appendingPathComponent(RelayProtocol.legacySocketName)
        guard let response = try? await request(["list"], socket: legacySocket),
              response.type == "tasks",
              let tasks = response.tasks else {
            throw RelayClientError.legacyDaemonUnavailable
        }
        let activeCount = tasks.lazy.filter { !$0.status.isTerminal }.count
        guard activeCount == 0 else {
            throw RelayClientError.legacyDaemonHasActiveTasks(activeCount)
        }
        _ = try await runCommand(
            executable: launchctl,
            arguments: ["bootout", service]
        )
    }

    private func waitForDaemon() async -> Bool {
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if await canPing() {
                return true
            }
        }
        return false
    }

    private func launchDaemon(replacingExistingJob: Bool) async throws {
        let relayd = try bundledBinary(named: "relayd")
        let taskStateDirectory = applicationDirectory.appendingPathComponent("tasks", isDirectory: true)
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(Self.daemonLabel)"
        let jobIsLoaded = (try? await runCommand(
            executable: launchctl,
            arguments: ["print", service]
        )) != nil

        if jobIsLoaded, !replacingExistingJob {
            return
        }
        if jobIsLoaded {
            _ = try? await runCommand(
                executable: launchctl,
                arguments: ["bootout", service]
            )
        }

        let propertyList: [String: Any] = [
            "Label": Self.daemonLabel,
            "ProgramArguments": [
                relayd.path,
                "--socket", socketURL.path,
                "--state-dir", taskStateDirectory.path,
            ],
            "WorkingDirectory": applicationDirectory.path,
            "ProcessType": "Background",
            "RunAtLoad": true,
            "StandardInputPath": "/dev/null",
            "StandardOutputPath": "/dev/null",
            "StandardErrorPath": daemonLogURL.path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: daemonPlistURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: daemonPlistURL.path
        )
        _ = try await runCommand(
            executable: launchctl,
            arguments: ["bootstrap", domain, daemonPlistURL.path]
        )
    }

    private func reloadAdapters() {
        let previousVersions = Dictionary(uniqueKeysWithValues: agents.compactMap { agent in
            agent.version.map { (agent.id, $0) }
        })
        agents = AdapterCatalog.load(
            bundledDirectory: bundledAdapterDirectory,
            userDirectory: adapterDirectory,
            home: homeDirectory,
            genericAdapter: genericAdapterURL,
            acpAdapter: acpAdapterURL,
            codexModels: mixModels,
            claudeModels: RelayClaudeModels.discover(
                binaryURL: RelayClaudeModels.resolveBinary(home: homeDirectory),
                accountConfigURL: homeDirectory.appendingPathComponent(".claude.json")
            )
        )
        for index in agents.indices where agents[index].version == nil {
            agents[index].version = previousVersions[agents[index].id]
        }
        selectFallbackAgentIfNeeded()
        loadAgentOptionValues()
    }

    private func selectFallbackAgentIfNeeded() {
        guard !agents.contains(where: { $0.id == selectedAgentID }) else { return }
        selectedAgentID = agents.first(where: { $0.id == "codex" })?.id
            ?? agents.first?.id
            ?? ""
    }

    private func synchronizeAdapters() async {
        for index in agents.indices where agents[index].canRegister {
            guard let executable = agents[index].adapterExecutablePath else { continue }
            var environment = agents[index].registrationEnvironment
            if agents[index].id == "mix" {
                do {
                    let node = try bundledBinary(named: "node")
                    guard let mixRunner = Self.bundledMixRunner() else {
                        throw RelayClientError.missingResource("mix-runtime/relay-mix.mjs")
                    }
                    environment["RELAY_NODE_PATH"] = node.path
                    environment["RELAY_MIX_RUNNER"] = mixRunner.path
                    environment["RELAY_MIX_RUNTIME_ROOT"] = mixRunner
                        .deletingLastPathComponent().path
                    environment["RELAY_MIX_STATE_DIR"] = applicationDirectory
                        .appendingPathComponent("mix", isDirectory: true).path
                } catch {
                    agents[index].health = .missing(error.localizedDescription)
                    continue
                }
            }
            var arguments = [
                "register-adapter",
                "--id", agents[index].id,
                "--executable", executable,
            ]
            for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
                arguments.append(contentsOf: ["--environment", "\(key)=\(value)"])
            }
            do {
                try await validateGenericManifest(agents[index])
                let response = try await request(arguments)
                guard response.type == "adapter_registered",
                      response.adapterID == agents[index].id else {
                    throw RelayClientError.invalidResponse(response.type)
                }
                agents[index].health = .ready
            } catch {
                agents[index].health = .invalid(error.localizedDescription)
            }
        }
    }

    private func validateGenericManifest(_ agent: RelayAgent) async throws {
        let validator: URL?
        let resource: String
        if agent.usesGenericRuntime {
            validator = genericAdapterURL
            resource = "generic-adapter"
        } else if agent.usesAcpRuntime {
            validator = acpAdapterURL
            resource = "acp-adapter"
        } else {
            return
        }
        guard let validator else {
            throw RelayClientError.missingResource(resource)
        }
        _ = try await runCommand(
            executable: validator,
            arguments: [
                "validate", "--spec", agent.manifestURL.standardizedFileURL.path,
            ]
        )
    }

    private func bundledBinary(named name: String) throws -> URL {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw RelayClientError.missingResource(name)
        }
        let url = resourceURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw RelayClientError.missingResource(name)
        }
        return url
    }

    func runCommand(
        executable: URL,
        arguments: [String],
        input: Data? = nil
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let inputPipe = input.map { _ in Pipe() }
            process.executableURL = executable
            process.arguments = arguments
            if let inputPipe {
                process.standardInput = inputPipe
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            if let input, let inputPipe {
                inputPipe.fileHandleForWriting.write(input)
                try inputPipe.fileHandleForWriting.close()
            }

            let outputTask = Task.detached {
                outputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let errorTask = Task.detached {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()
            let output = await outputTask.value
            let errorOutput = await errorTask.value
            guard process.terminationStatus == 0 else {
                let message = String(data: errorOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw RelayClientError.commandFailed(
                    message?.isEmpty == false
                        ? message!
                        : "command exited with status \(process.terminationStatus)"
                )
            }
            return output
        }.value
    }

    private func adapterOptions(for adapterID: String) -> [String: String] {
        var values: [String: String] = [:]
        let agent = agents.first { $0.id == adapterID }
        if adapterID == "codex", codexMode == .plan {
            values["codex_mode"] = "plan"
        }
        if agent?.capabilities.contains("mix_model_options") == true {
            values["codex_model"] = mixModel
            values["codex_reasoning_effort"] = mixEffort
        }
        for option in agent?.options ?? [] {
            values[option.key] = agentOptionValue(agentID: adapterID, option: option)
        }
        return values
    }

    private func adapterOptionArguments(
        for adapterID: String, overrides: [String: String] = [:]
    ) -> [String] {
        adapterOptions(for: adapterID)
            .merging(overrides) { _, override in override }
            .sorted(by: { $0.key < $1.key })
            .flatMap { ["--option", "\($0.key)=\($0.value)"] }
    }

    // MARK: - Seat personas

    func resolveMember(_ memberID: String) -> RelayMemberResolution? {
        RelayPersonaStore.resolve(
            memberID: memberID, personas: personas, agents: agents
        )
    }

    func savePersona(_ persona: RelayPersona) {
        if let index = personas.firstIndex(where: { $0.id == persona.id }) {
            personas[index] = persona
        } else {
            guard personas.count < RelayPersonaStore.maxCount else { return }
            personas.append(persona)
        }
        RelayPersonaStore.save(personas)
    }

    func deletePersona(id: UUID) {
        personas.removeAll { $0.id == id }
        RelayPersonaStore.save(personas)
    }

    // MARK: - Task lifecycle hooks

    func saveTaskHook(_ hook: RelayTaskHook) {
        if let index = taskHooks.firstIndex(where: { $0.id == hook.id }) {
            taskHooks[index] = hook
        } else {
            guard taskHooks.count < RelayTaskHookStore.maxCount else { return }
            taskHooks.append(hook)
        }
        RelayTaskHookStore.save(taskHooks)
    }

    func deleteTaskHook(id: UUID) {
        taskHooks.removeAll { $0.id == id }
        RelayTaskHookStore.save(taskHooks)
    }

    func agentOptionValue(agentID: String, option: RelayAgentOption) -> String {
        agentOptionValues[agentID]?[option.key] ?? option.defaultValue
    }

    func setAgentOption(agentID: String, key: String, value: String) {
        guard let agent = agents.first(where: { $0.id == agentID }),
              let option = agent.options.first(where: { $0.key == key }),
              option.values.contains(value) else { return }
        agentOptionValues[agentID, default: [:]][key] = value
        UserDefaults.standard.set(value, forKey: "agentOption.\(agentID).\(key)")
    }

    private func loadAgentOptionValues() {
        var values: [String: [String: String]] = [:]
        for agent in agents where !agent.options.isEmpty {
            var perAgent: [String: String] = [:]
            for option in agent.options {
                let stored = UserDefaults.standard.string(
                    forKey: "agentOption.\(agent.id).\(option.key)"
                )
                perAgent[option.key] = stored
                    .flatMap { option.values.contains($0) ? $0 : nil }
                    ?? option.defaultValue
            }
            values[agent.id] = perAgent
        }
        agentOptionValues = values
    }

    private func applyAdapterSettings(from task: RelayTask) {
        if task.adapterID == "codex" {
            setCodexMode(
                task.adapterOptions["codex_mode"] == "plan" ? .plan : .defaultMode,
                persist: false
            )
            return
        }
        guard agents.first(where: { $0.id == task.adapterID })?
            .capabilities.contains("mix_model_options") == true else { return }
        if let model = task.adapterOptions["codex_model"], mixModels.contains(model) {
            setMixModel(model, persist: false)
        }
        if let effort = task.adapterOptions["codex_reasoning_effort"],
           mixEfforts.contains(effort) {
            setMixEffort(effort, persist: false)
        }
    }

    private static let allMixEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    private static func loadCodexModels(home: URL) -> (
        models: [String],
        efforts: [String: [String]]
    ) {
        let cache = home.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: cache),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = root["models"] as? [[String: Any]] else {
            return (["auto", "gpt-5.6-sol"], ["auto": allMixEfforts])
        }
        let entries = rawModels.compactMap { model -> (String, Int, [String])? in
            guard model["visibility"] as? String == "list",
                  let slug = model["slug"] as? String else {
                return nil
            }
            let priority = model["priority"] as? Int ?? Int.max
            let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { $0["effort"] as? String }
                .filter { allMixEfforts.contains($0) }
            return (slug, priority, levels.isEmpty ? allMixEfforts : levels)
        }
        .sorted { $0.1 < $1.1 }
        var models = ["auto"]
        var efforts = ["auto": allMixEfforts]
        for (slug, _, levels) in entries where !models.contains(slug) {
            models.append(slug)
            efforts[slug] = levels
        }
        if !models.contains("gpt-5.6-sol") {
            models.append("gpt-5.6-sol")
            efforts["gpt-5.6-sol"] = allMixEfforts
        }
        return (models, efforts)
    }

    private static func bundledMixRunner() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let runner = resourceURL
            .appendingPathComponent("mix-runtime", isDirectory: true)
            .appendingPathComponent("relay-mix.mjs")
        return FileManager.default.isExecutableFile(atPath: runner.path) ? runner : nil
    }

}
