import Foundation

enum RelayAgentHealth: Hashable {
    case checking
    case ready
    case missing(String)
    case invalid(String)

    var label: String {
        switch self {
        case .checking: "CHECKING"
        case .ready: "READY"
        case .missing: "MISSING"
        case .invalid: "INVALID"
        }
    }

    var reason: String? {
        switch self {
        case .checking, .ready: nil
        case let .missing(reason), let .invalid(reason): reason
        }
    }
}

struct RelayAgentOption: Hashable {
    let key: String
    let label: String
    let values: [String]
    let defaultValue: String
}

struct RelayAgent: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let manifestURL: URL
    let adapterExecutablePath: String?
    let usesGenericRuntime: Bool
    let registrationEnvironment: [String: String]
    let capabilities: Set<String>
    let versionExecutablePath: String?
    let versionArguments: [String]
    var options: [RelayAgentOption] = []
    var version: String?
    var health: RelayAgentHealth

    var isAvailable: Bool { health == .ready }
    var canRegister: Bool {
        adapterExecutablePath != nil && health == .checking
    }
}

struct LineCLIConfiguration: Equatable {
    let id: String
    let name: String
    let executablePath: String
    let arguments: [String]
}

private struct AdapterManifest: Decodable {
    let schemaVersion: Int
    let id: String
    let name: String
    let detail: String
    let adapterExecutable: String?
    let generic: AdapterGenericSpec?
    let capabilities: [String]
    let requirements: [AdapterRequirement]
    let options: [AdapterManifestOption]?
    let versionLabel: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case name
        case detail
        case adapterExecutable = "adapter_executable"
        case generic
        case capabilities
        case requirements
        case options
        case versionLabel = "version_label"
    }
}

private struct AdapterManifestOption: Decodable {
    let key: String
    let label: String?
    let values: [String]
    let `default`: String?
}

private struct AdapterGenericSpec: Decodable {
    let command: String
    let arguments: [String]?
    let newSessionArguments: [String]?
    let resumeArguments: [String]?
    let output: String?
    let textPaths: [String]?

    enum CodingKeys: String, CodingKey {
        case command
        case arguments
        case newSessionArguments = "new_session_arguments"
        case resumeArguments = "resume_arguments"
        case output
        case textPaths = "text_paths"
    }
}

private struct AdapterRequirement: Decodable {
    let name: String
    let environment: String
    let candidates: [String]
    let versionArguments: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case environment
        case candidates
        case versionArguments = "version_arguments"
    }
}

enum AdapterCatalog {
    static func load(
        bundledDirectory: URL?,
        userDirectory: URL,
        home: URL,
        genericAdapter: URL? = nil
    ) -> [RelayAgent] {
        var agents: [RelayAgent] = []
        var identifiers = Set<String>()
        let directories = [bundledDirectory, userDirectory].compactMap { $0 }
        for directory in directories {
            let urls = ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in urls {
                var agent = loadManifest(at: url, home: home, genericAdapter: genericAdapter)
                if identifiers.contains(agent.id), !agent.id.hasPrefix("invalid:") {
                    agent = invalidAgent(
                        at: url,
                        name: agent.name,
                        reason: "Duplicate adapter ID: \(agent.id)"
                    )
                } else if !agent.id.hasPrefix("invalid:") {
                    identifiers.insert(agent.id)
                }
                agents.append(agent)
            }
        }
        return agents
    }

    static func loadManifest(at url: URL, home: URL, genericAdapter: URL? = nil) -> RelayAgent {
        let manifest: AdapterManifest
        do {
            manifest = try JSONDecoder().decode(AdapterManifest.self, from: Data(contentsOf: url))
            try validate(manifest)
        } catch {
            return invalidAgent(
                at: url,
                name: url.deletingPathExtension().lastPathComponent,
                reason: error.localizedDescription
            )
        }

        let executable: URL
        if let adapterExecutable = manifest.adapterExecutable {
            executable = resolvePath(
                adapterExecutable,
                relativeTo: url.deletingLastPathComponent(),
                home: home
            )
        } else if let genericAdapter {
            executable = genericAdapter
        } else {
            return RelayAgent(
                id: manifest.id,
                name: manifest.name,
                detail: manifest.detail,
                manifestURL: url,
                adapterExecutablePath: nil,
                usesGenericRuntime: true,
                registrationEnvironment: [:],
                capabilities: Set(manifest.capabilities),
                versionExecutablePath: nil,
                versionArguments: [],
                version: manifest.versionLabel,
                health: .missing("Generic adapter runtime is unavailable")
            )
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return RelayAgent(
                id: manifest.id,
                name: manifest.name,
                detail: manifest.detail,
                manifestURL: url,
                adapterExecutablePath: nil,
                usesGenericRuntime: manifest.generic != nil,
                registrationEnvironment: [:],
                capabilities: Set(manifest.capabilities),
                versionExecutablePath: nil,
                versionArguments: [],
                version: manifest.versionLabel,
                health: .missing("Adapter executable not found: \(executable.path)")
            )
        }

        var environment: [String: String] = [:]
        var versionExecutablePath: String?
        var versionArguments: [String] = []
        for requirement in manifest.requirements {
            let candidates = requirement.candidates.map {
                resolvePath(
                    $0,
                    relativeTo: url.deletingLastPathComponent(),
                    home: home
                )
            }
            guard let resolved = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }) else {
                return RelayAgent(
                    id: manifest.id,
                    name: manifest.name,
                    detail: manifest.detail,
                    manifestURL: url,
                    adapterExecutablePath: executable.path,
                    usesGenericRuntime: manifest.generic != nil,
                    registrationEnvironment: [:],
                    capabilities: Set(manifest.capabilities),
                    versionExecutablePath: nil,
                    versionArguments: [],
                    version: manifest.versionLabel,
                    health: .missing("\(requirement.name) was not found")
                )
            }
            environment[requirement.environment] = resolved.path
            if versionExecutablePath == nil, !requirement.versionArguments.isEmpty {
                versionExecutablePath = resolved.path
                versionArguments = requirement.versionArguments
            }
        }
        if manifest.generic != nil {
            environment["RELAY_GENERIC_SPEC"] = url.standardizedFileURL.path
        }

        return RelayAgent(
            id: manifest.id,
            name: manifest.name,
            detail: manifest.detail,
            manifestURL: url,
            adapterExecutablePath: executable.path,
            usesGenericRuntime: manifest.generic != nil,
            registrationEnvironment: environment,
            capabilities: Set(manifest.capabilities),
            versionExecutablePath: versionExecutablePath,
            versionArguments: versionArguments,
            options: (manifest.options ?? []).map { option in
                RelayAgentOption(
                    key: option.key,
                    label: option.label ?? option.key.uppercased(),
                    values: option.values,
                    defaultValue: option.default ?? option.values.first ?? ""
                )
            },
            version: manifest.versionLabel,
            health: .checking
        )
    }

    static func genericManifestData(
        id rawID: String,
        name rawName: String,
        executablePath: String,
        arguments: [String]
    ) throws -> Data {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = id.utf8.first,
              (48...57).contains(first) || (97...122).contains(first),
              id.utf8.count <= 32,
              id.utf8.allSatisfy({
                  (48...57).contains($0) || (97...122).contains($0)
                      || $0 == 45 || $0 == 95
              }) else {
            throw catalogError(
                "CLI ID must start with a lowercase letter or number and then use letters, numbers, - or _"
            )
        }
        guard !name.isEmpty,
              name.utf8.count <= 64,
              name.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw catalogError("CLI name must contain between 1 and 64 bytes")
        }
        guard executablePath.hasPrefix("/"),
              executablePath.utf8.count <= 1024,
              executablePath.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw catalogError("CLI executable must use an absolute path")
        }
        guard arguments.count <= 32,
              arguments.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains(where: \.isNewline)
              }) else {
            throw catalogError("CLI arguments must contain 1 to 512 bytes per line")
        }

        let environment = genericEnvironmentKey(for: id)
        let manifest: [String: Any] = [
            "schema_version": 1,
            "id": id,
            "name": name,
            "detail": "Custom line CLI: \(name)",
            "capabilities": [],
            "generic": [
                "command": environment,
                "arguments": arguments,
            ],
            "requirements": [[
                "name": name,
                "environment": environment,
                "candidates": [executablePath],
                "version_arguments": [],
            ]],
        ]
        return try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func lineCLIConfiguration(at url: URL) -> LineCLIConfiguration? {
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == [
                      "schema_version", "id", "name", "detail", "capabilities", "generic",
                      "requirements",
                  ],
                  let genericObject = object["generic"] as? [String: Any],
                  Set(genericObject.keys) == ["command", "arguments"],
                  let requirementObjects = object["requirements"] as? [[String: Any]],
                  requirementObjects.count == 1,
                  let requirementObject = requirementObjects.first,
                  Set(requirementObject.keys) == [
                      "name", "environment", "candidates", "version_arguments",
                  ] else {
                return nil
            }

            let manifest = try JSONDecoder().decode(AdapterManifest.self, from: data)
            try validate(manifest)
            guard manifest.adapterExecutable == nil,
                  manifest.capabilities.isEmpty,
                  manifest.options == nil,
                  manifest.versionLabel == nil,
                  let generic = manifest.generic,
                  generic.newSessionArguments == nil,
                  generic.resumeArguments == nil,
                  generic.output == nil,
                  generic.textPaths == nil,
                  let arguments = generic.arguments,
                  manifest.requirements.count == 1,
                  let requirement = manifest.requirements.first,
                  requirement.name == manifest.name,
                  requirement.environment == genericEnvironmentKey(for: manifest.id),
                  generic.command == requirement.environment,
                  requirement.candidates.count == 1,
                  let executablePath = requirement.candidates.first,
                  executablePath.hasPrefix("/"),
                  requirement.versionArguments.isEmpty,
                  manifest.detail == "Custom line CLI: \(manifest.name)" else {
                return nil
            }
            return LineCLIConfiguration(
                id: manifest.id,
                name: manifest.name,
                executablePath: executablePath,
                arguments: arguments
            )
        } catch {
            return nil
        }
    }

    private static func genericEnvironmentKey(for id: String) -> String {
        "RELAY_" + id.uppercased().map {
            $0.isLetter || $0.isNumber ? String($0) : "_"
        }.joined() + "_PATH"
    }

    private static func validate(_ manifest: AdapterManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw catalogError("Unsupported manifest schema: \(manifest.schemaVersion)")
        }
        guard validIdentifier(manifest.id), manifest.id.utf8.count <= 256 else {
            throw catalogError("Adapter ID is invalid")
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.name.utf8.count <= 64 else {
            throw catalogError("Adapter name is invalid")
        }
        guard !manifest.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.detail.utf8.count <= 160 else {
            throw catalogError("Adapter detail is invalid")
        }
        let options = manifest.options ?? []
        try validateOptionPresentation(options)
        if manifest.generic == nil {
            try validateAdapterOptions(options)
        }
        switch (manifest.adapterExecutable, manifest.generic) {
        case (nil, nil):
            throw catalogError("Adapter must declare adapter_executable or generic")
        case (.some, .some):
            throw catalogError("adapter_executable and generic cannot both be declared")
        case let (.some(adapterExecutable), nil):
            guard !adapterExecutable.isEmpty, adapterExecutable.utf8.count <= 1024 else {
                throw catalogError("Adapter executable path is invalid")
            }
        case (nil, .some):
            break
        }
        guard manifest.capabilities.count <= 16,
              Set(manifest.capabilities).count == manifest.capabilities.count,
              manifest.capabilities.allSatisfy({ validCapability($0) }) else {
            throw catalogError("Adapter capabilities are invalid")
        }
        guard manifest.requirements.count <= 16 else {
            throw catalogError("Adapter has too many requirements")
        }
        var environmentKeys = Set<String>()
        for requirement in manifest.requirements {
            guard !requirement.name.isEmpty, requirement.name.utf8.count <= 64 else {
                throw catalogError("Requirement name is invalid")
            }
            guard validEnvironmentKey(requirement.environment),
                  environmentKeys.insert(requirement.environment).inserted else {
                throw catalogError("Requirement environment key is invalid")
            }
            guard !requirement.candidates.isEmpty,
                  requirement.candidates.count <= 16,
                  requirement.candidates.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else {
                throw catalogError("Requirement candidates are invalid")
            }
            guard requirement.versionArguments.count <= 8,
                  requirement.versionArguments.allSatisfy({ $0.utf8.count <= 128 }) else {
                throw catalogError("Requirement version arguments are invalid")
            }
        }
    }

    static func isUserManifest(_ manifestURL: URL, userDirectory: URL) -> Bool {
        manifestURL.standardizedFileURL.path
            .hasPrefix(userDirectory.standardizedFileURL.path + "/")
    }

    static func importBlockReason(
        candidateID: String,
        destination: URL,
        agents: [RelayAgent]
    ) -> String? {
        agents.first { agent in
            agent.id == candidateID
                && agent.manifestURL.standardizedFileURL.path
                    != destination.standardizedFileURL.path
        }
        .map { "Adapter ID \(candidateID) is already provided by \($0.manifestURL.lastPathComponent)" }
    }

    private static func validateOptionPresentation(_ options: [AdapterManifestOption]) throws {
        for option in options {
            if let label = option.label, label.isEmpty || label.utf8.count > 24 {
                throw catalogError("Manifest option label is invalid: \(option.key)")
            }
        }
    }

    private static func validateAdapterOptions(_ options: [AdapterManifestOption]) throws {
        guard options.count <= 8 else {
            throw catalogError("A manifest allows at most 8 options")
        }
        var keys = Set<String>()
        for option in options {
            guard !option.key.isEmpty,
                  option.key.utf8.count <= 32,
                  !option.key.hasPrefix("relay"),
                  option.key.utf8.allSatisfy({
                      (48...57).contains($0) || (97...122).contains($0)
                          || $0 == 95 || $0 == 45
                  }),
                  keys.insert(option.key).inserted else {
                throw catalogError("Manifest option key is invalid: \(option.key)")
            }
            guard (1...24).contains(option.values.count),
                  option.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else {
                throw catalogError("Manifest option values are invalid: \(option.key)")
            }
            if let defaultValue = option.default, !option.values.contains(defaultValue) {
                throw catalogError(
                    "Manifest option default is not among its values: \(option.key)"
                )
            }
        }
    }

    private static func resolvePath(_ path: String, relativeTo directory: URL, home: URL) -> URL {
        if path == "~" {
            return home.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return directory.appendingPathComponent(path).standardizedFileURL
    }

    private static func invalidAgent(at url: URL, name: String, reason: String) -> RelayAgent {
        RelayAgent(
            id: "invalid:\(url.path)",
            name: name,
            detail: "Adapter manifest",
            manifestURL: url,
            adapterExecutablePath: nil,
            usesGenericRuntime: false,
            registrationEnvironment: [:],
            capabilities: [],
            versionExecutablePath: nil,
            versionArguments: [],
            version: nil,
            health: .invalid(reason)
        )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 46
        }
    }

    private static func validCapability(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 46
        }
    }

    private static func validEnvironmentKey(_ value: String) -> Bool {
        value.hasPrefix("RELAY_") && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || $0 == 95
        }
    }

    private static func catalogError(_ message: String) -> NSError {
        NSError(domain: "Relay.AdapterCatalog", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
