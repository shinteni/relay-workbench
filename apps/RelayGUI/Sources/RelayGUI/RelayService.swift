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

private enum RelayClientError: LocalizedError {
    case missingResource(String)
    case commandFailed(String)
    case invalidResponse(String)
    case daemonUnavailable
    case invalidDirectory(String)
    case unavailableAgent(String)

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
        }
    }
}

@MainActor
final class RelayService: ObservableObject {
    @Published private(set) var agents: [RelayAgent]
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
    @Published var mixModel: String
    @Published var mixEffort: String
    @Published var codexMode: RelayCodexMode
    @Published var errorMessage: String?

    private var hasStarted = false
    private var isComposingNewThread = false
    private let mixEffortsByModel: [String: [String]]
    private let applicationDirectory: URL
    private let adapterDirectory: URL
    private let bundledAdapterDirectory: URL?
    private let homeDirectory: URL
    private let runtimeDirectory: URL
    private let socketURL: URL
    private static let daemonLabel = "local.tenishin.relay.daemon.v7"

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        applicationDirectory = support.appendingPathComponent("Relay", isDirectory: true)
        adapterDirectory = applicationDirectory.appendingPathComponent("adapters", isDirectory: true)
        bundledAdapterDirectory = Bundle.main.resourceURL?
            .appendingPathComponent("adapters", isDirectory: true)
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        runtimeDirectory = applicationDirectory.appendingPathComponent("runtime", isDirectory: true)
        socketURL = runtimeDirectory.appendingPathComponent("relay-v7.sock")
        let home = homeDirectory
        let savedDirectory = UserDefaults.standard.string(forKey: "workingDirectory")
        workingDirectory = savedDirectory ?? home.path
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
        agents = AdapterCatalog.load(
            bundledDirectory: bundledAdapterDirectory,
            userDirectory: adapterDirectory,
            home: home
        )
        if !agents.contains(where: { $0.id == selectedAgentID }) {
            selectedAgentID = agents.first?.id ?? ""
        }
    }

    var selectedTask: RelayTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    var selectedAgent: RelayAgent? {
        agents.first { $0.id == selectedAgentID }
    }

    var canSubmit: Bool {
        guard daemonState == .online, selectedAgent?.isAvailable == true else { return false }
        return selectedTask?.status.isTerminal != false
    }

    func run() async {
        guard !hasStarted else { return }
        hasStarted = true
        await connect()

        while !Task.isCancelled {
            if daemonState == .online {
                await refreshTasks(showErrors: false)
            }
            try? await Task.sleep(for: .seconds(1))
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

    func selectAgent(_ id: String) {
        guard agents.contains(where: { $0.id == id }) else { return }
        selectedAgentID = id
        selectedTaskID = nil
        isComposingNewThread = true
        output = []
        outputTruncated = false
        errorMessage = nil
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
        Task { await refreshSelectedOutput(showErrors: true) }
    }

    func startNewThread() {
        selectedTaskID = nil
        selectFallbackAgentIfNeeded()
        isComposingNewThread = true
        output = []
        outputTruncated = false
        errorMessage = nil
    }

    func setWorkingDirectory(_ path: String) {
        workingDirectory = path
        UserDefaults.standard.set(path, forKey: "workingDirectory")
    }

    func setMixModel(_ model: String) {
        guard mixModels.contains(model) else { return }
        mixModel = model
        mixEfforts = mixEffortsByModel[model] ?? Self.allMixEfforts
        if !mixEfforts.contains(mixEffort) {
            mixEffort = mixEfforts.contains("max") ? "max" : mixEfforts.last ?? "high"
            UserDefaults.standard.set(mixEffort, forKey: "mixEffort")
        }
        UserDefaults.standard.set(model, forKey: "mixModel")
    }

    func setMixEffort(_ effort: String) {
        guard mixEfforts.contains(effort) else {
            return
        }
        mixEffort = effort
        UserDefaults.standard.set(effort, forKey: "mixEffort")
    }

    func setCodexMode(_ mode: RelayCodexMode) {
        codexMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "codexMode")
    }

    func refreshTasks(showErrors: Bool = true) async {
        do {
            let response = try await request(["list"])
            guard response.type == "tasks", let receivedTasks = response.tasks else {
                throw RelayClientError.invalidResponse(response.type)
            }
            tasks = receivedTasks.sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
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
            await refreshSelectedOutput(showErrors: showErrors)
            daemonState = .online
            if showErrors {
                errorMessage = nil
            }
        } catch {
            daemonState = await canPing() ? .online : .offline
            if showErrors {
                errorMessage = error.localizedDescription
            }
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
        guard let task = selectedTask,
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
            if !(await canPing()) {
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

    private func refreshSelectedOutput(showErrors: Bool) async {
        guard let selectedTaskID else {
            output = []
            outputTruncated = false
            return
        }
        do {
            let response = try await request(["output", selectedTaskID])
            guard response.type == "task_output", let receivedOutput = response.output else {
                throw RelayClientError.invalidResponse(response.type)
            }
            output = receivedOutput
            outputTruncated = response.truncated ?? false
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
              response.protocolVersion == 7 else {
            return false
        }
        daemonVersion = response.daemonVersion
        return true
    }

    private func request(_ arguments: [String], input: Data? = nil) async throws -> RelayResponse {
        let relayctl = try bundledBinary(named: "relayctl")
        let data = try await runCommand(
            executable: relayctl,
            arguments: ["--socket", socketURL.path] + arguments,
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

        let plistURL = runtimeDirectory.appendingPathComponent("relayd-v7.plist")
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
            "StandardErrorPath": "/dev/null",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: plistURL.path
        )
        _ = try await runCommand(
            executable: launchctl,
            arguments: ["bootstrap", domain, plistURL.path]
        )
    }

    private func reloadAdapters() {
        let previousVersions = Dictionary(uniqueKeysWithValues: agents.compactMap { agent in
            agent.version.map { (agent.id, $0) }
        })
        agents = AdapterCatalog.load(
            bundledDirectory: bundledAdapterDirectory,
            userDirectory: adapterDirectory,
            home: homeDirectory
        )
        for index in agents.indices where agents[index].version == nil {
            agents[index].version = previousVersions[agents[index].id]
        }
        selectFallbackAgentIfNeeded()
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

    private func runCommand(
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

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
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

    private func adapterOptionArguments(for adapterID: String) -> [String] {
        if adapterID == "codex", codexMode == .plan {
            return ["--option", "codex_mode=plan"]
        }
        if agents.first(where: { $0.id == adapterID })?
            .capabilities.contains("mix_model_options") == true {
            return [
                "--option", "codex_model=\(mixModel)",
                "--option", "codex_reasoning_effort=\(mixEffort)",
            ]
        }
        return []
    }

    private func applyAdapterSettings(from task: RelayTask) {
        if task.adapterID == "codex" {
            setCodexMode(
                task.adapterOptions["codex_mode"] == "plan" ? .plan : .defaultMode
            )
            return
        }
        guard agents.first(where: { $0.id == task.adapterID })?
            .capabilities.contains("mix_model_options") == true else { return }
        if let model = task.adapterOptions["codex_model"], mixModels.contains(model) {
            setMixModel(model)
        }
        if let effort = task.adapterOptions["codex_reasoning_effort"],
           mixEfforts.contains(effort) {
            setMixEffort(effort)
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
