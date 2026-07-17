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

struct RelayAgent: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let manifestURL: URL
    let adapterExecutablePath: String?
    let registrationEnvironment: [String: String]
    let capabilities: Set<String>
    let versionExecutablePath: String?
    let versionArguments: [String]
    var version: String?
    var health: RelayAgentHealth

    var isAvailable: Bool { health == .ready }
    var canRegister: Bool {
        adapterExecutablePath != nil && health == .checking
    }
}

private struct AdapterManifest: Decodable {
    let schemaVersion: Int
    let id: String
    let name: String
    let detail: String
    let adapterExecutable: String
    let capabilities: [String]
    let requirements: [AdapterRequirement]
    let versionLabel: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case name
        case detail
        case adapterExecutable = "adapter_executable"
        case capabilities
        case requirements
        case versionLabel = "version_label"
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
        home: URL
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
                var agent = loadManifest(at: url, home: home)
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

    static func loadManifest(at url: URL, home: URL) -> RelayAgent {
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

        let executable = resolvePath(
            manifest.adapterExecutable,
            relativeTo: url.deletingLastPathComponent(),
            home: home
        )
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return RelayAgent(
                id: manifest.id,
                name: manifest.name,
                detail: manifest.detail,
                manifestURL: url,
                adapterExecutablePath: nil,
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

        return RelayAgent(
            id: manifest.id,
            name: manifest.name,
            detail: manifest.detail,
            manifestURL: url,
            adapterExecutablePath: executable.path,
            registrationEnvironment: environment,
            capabilities: Set(manifest.capabilities),
            versionExecutablePath: versionExecutablePath,
            versionArguments: versionArguments,
            version: manifest.versionLabel,
            health: .checking
        )
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
        guard !manifest.adapterExecutable.isEmpty,
              manifest.adapterExecutable.utf8.count <= 1024 else {
            throw catalogError("Adapter executable path is invalid")
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
