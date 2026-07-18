import Foundation
import Testing
@testable import RelayGUI

struct AdapterCatalogTests {
    @Test
    func loadsValidManifestAndResolvesRequirement() throws {
        let root = try temporaryDirectory()
        let adapter = root.appendingPathComponent("adapter")
        let cli = root.appendingPathComponent("cli")
        try executable(at: adapter)
        try executable(at: cli)
        let manifest = root.appendingPathComponent("example.json")
        try Data("""
        {
          "schema_version": 1,
          "id": "example",
          "name": "Example",
          "detail": "Example CLI",
          "adapter_executable": "adapter",
          "capabilities": ["session_resume"],
          "requirements": [{
            "name": "Example CLI",
            "environment": "RELAY_EXAMPLE_PATH",
            "candidates": ["cli"],
            "version_arguments": ["--version"]
          }]
        }
        """.utf8).write(to: manifest)

        let agent = AdapterCatalog.loadManifest(at: manifest, home: root)

        #expect(agent.id == "example")
        #expect(agent.health == .checking)
        #expect(agent.adapterExecutablePath == adapter.path)
        #expect(agent.registrationEnvironment["RELAY_EXAMPLE_PATH"] == cli.path)
        #expect(agent.capabilities == ["session_resume"])
    }

    @Test
    func rejectsUnsupportedSchema() throws {
        let root = try temporaryDirectory()
        let manifest = root.appendingPathComponent("invalid.json")
        try Data("""
        {
          "schema_version": 2,
          "id": "invalid",
          "name": "Invalid",
          "detail": "Invalid CLI",
          "adapter_executable": "adapter",
          "capabilities": [],
          "requirements": []
        }
        """.utf8).write(to: manifest)

        let agent = AdapterCatalog.loadManifest(at: manifest, home: root)

        guard case let .invalid(reason) = agent.health else {
            Issue.record("Manifest should be invalid")
            return
        }
        #expect(reason.contains("Unsupported manifest schema"))
    }

    @Test
    func reportsDuplicateIdentifiers() throws {
        let root = try temporaryDirectory()
        let bundled = root.appendingPathComponent("bundled")
        let user = root.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let adapter = root.appendingPathComponent("adapter")
        try executable(at: adapter)
        let manifest = """
        {
          "schema_version": 1,
          "id": "same",
          "name": "Same",
          "detail": "Same CLI",
          "adapter_executable": "\(adapter.path)",
          "capabilities": [],
          "requirements": []
        }
        """
        try Data(manifest.utf8).write(to: bundled.appendingPathComponent("same.json"))
        try Data(manifest.utf8).write(to: user.appendingPathComponent("same.json"))

        let agents = AdapterCatalog.load(
            bundledDirectory: bundled,
            userDirectory: user,
            home: root
        )

        #expect(agents.count == 2)
        #expect(agents[0].id == "same")
        guard case let .invalid(reason) = agents[1].health else {
            Issue.record("Duplicate manifest should be invalid")
            return
        }
        #expect(reason.contains("Duplicate adapter ID"))
    }

    @Test
    func loadsGenericManifestWithBuiltinAdapterAndSpecEnvironment() throws {
        let root = try temporaryDirectory()
        let genericAdapter = root.appendingPathComponent("generic-adapter")
        let cli = root.appendingPathComponent("cli")
        try executable(at: genericAdapter)
        try executable(at: cli)
        let manifest = root.appendingPathComponent("example.json")
        try Data("""
        {
          "schema_version": 1,
          "id": "example",
          "name": "Example",
          "detail": "Example CLI",
          "capabilities": ["session_resume"],
          "generic": {
            "command": "RELAY_EXAMPLE_PATH",
            "arguments": ["--quiet"],
            "resume_arguments": ["--resume", "{session}"]
          },
          "requirements": [{
            "name": "Example CLI",
            "environment": "RELAY_EXAMPLE_PATH",
            "candidates": ["cli"],
            "version_arguments": ["--version"]
          }]
        }
        """.utf8).write(to: manifest)

        let agent = AdapterCatalog.loadManifest(
            at: manifest,
            home: root,
            genericAdapter: genericAdapter
        )

        #expect(agent.health == .checking)
        #expect(agent.adapterExecutablePath == genericAdapter.path)
        #expect(agent.registrationEnvironment["RELAY_EXAMPLE_PATH"] == cli.path)
        #expect(agent.registrationEnvironment["RELAY_GENERIC_SPEC"] == manifest.path)
    }

    @Test
    func genericManifestWithoutRuntimeIsMissing() throws {
        let root = try temporaryDirectory()
        let manifest = root.appendingPathComponent("example.json")
        try Data("""
        {
          "schema_version": 1,
          "id": "example",
          "name": "Example",
          "detail": "Example CLI",
          "capabilities": [],
          "generic": {"command": "RELAY_EXAMPLE_PATH"},
          "requirements": [{
            "name": "Example CLI",
            "environment": "RELAY_EXAMPLE_PATH",
            "candidates": ["cli"],
            "version_arguments": []
          }]
        }
        """.utf8).write(to: manifest)

        let agent = AdapterCatalog.loadManifest(at: manifest, home: root)

        #expect(agent.health == .missing("Generic adapter runtime is unavailable"))
    }

    @Test
    func defersUnknownGenericPlaceholderToRuntime() throws {
        let root = try temporaryDirectory()
        let genericAdapter = root.appendingPathComponent("generic-adapter")
        let cli = root.appendingPathComponent("cli")
        try executable(at: genericAdapter)
        try executable(at: cli)
        let manifest = root.appendingPathComponent("example.json")
        try Data("""
        {
          "schema_version": 1,
          "id": "example",
          "name": "Example",
          "detail": "Example CLI",
          "capabilities": [],
          "generic": {
            "command": "RELAY_EXAMPLE_PATH",
            "arguments": ["{model}"]
          },
          "requirements": [{
            "name": "Example CLI",
            "environment": "RELAY_EXAMPLE_PATH",
            "candidates": ["cli"],
            "version_arguments": []
          }]
        }
        """.utf8).write(to: manifest)

        let agent = AdapterCatalog.loadManifest(
            at: manifest,
            home: root,
            genericAdapter: genericAdapter
        )

        #expect(agent.health == .checking)
        #expect(agent.usesGenericRuntime)
    }

    @Test
    func defersJsonlTextPathRulesToRuntime() throws {
        let root = try temporaryDirectory()
        let genericAdapter = root.appendingPathComponent("generic-adapter")
        let cli = root.appendingPathComponent("cli")
        try executable(at: genericAdapter)
        try executable(at: cli)

        func manifest(_ generic: String) throws -> RelayAgent {
            let url = root.appendingPathComponent("\(UUID().uuidString).json")
            try Data("""
            {
              "schema_version": 1,
              "id": "example",
              "name": "Example",
              "detail": "Example CLI",
              "capabilities": [],
              "generic": \(generic),
              "requirements": [{
                "name": "Example CLI",
                "environment": "RELAY_EXAMPLE_PATH",
                "candidates": ["cli"],
                "version_arguments": []
              }]
            }
            """.utf8).write(to: url)
            return AdapterCatalog.loadManifest(at: url, home: root, genericAdapter: genericAdapter)
        }

        let valid = try manifest(
            #"{"command": "RELAY_EXAMPLE_PATH", "output": "jsonl", "text_paths": ["message.content.0.text"]}"#
        )
        #expect(valid.health == .checking)

        let missingPaths = try manifest(
            #"{"command": "RELAY_EXAMPLE_PATH", "output": "jsonl"}"#
        )
        #expect(missingPaths.health == .checking)

        let pathsWithoutJsonl = try manifest(
            #"{"command": "RELAY_EXAMPLE_PATH", "text_paths": ["response"]}"#
        )
        #expect(pathsWithoutJsonl.health == .checking)
    }

    @Test
    func parsesDeclaredOptionsAndDefersPlaceholderValidation() throws {
        let root = try temporaryDirectory()
        let genericAdapter = root.appendingPathComponent("generic-adapter")
        let cli = root.appendingPathComponent("cli")
        try executable(at: genericAdapter)
        try executable(at: cli)

        func manifest(_ body: String) throws -> RelayAgent {
            let url = root.appendingPathComponent("\(UUID().uuidString).json")
            try Data(body.utf8).write(to: url)
            return AdapterCatalog.loadManifest(
                at: url,
                home: root,
                genericAdapter: genericAdapter
            )
        }

        let valid = try manifest("""
        {
          "schema_version": 1,
          "id": "example",
          "name": "Example",
          "detail": "Example CLI",
          "capabilities": [],
          "options": [
            {"key": "model", "values": ["a", "b"], "default": "b"}
          ],
          "generic": {
            "command": "RELAY_EXAMPLE_PATH",
            "arguments": ["run", "{option:model}"]
          },
          "requirements": [{
            "name": "Example CLI",
            "environment": "RELAY_EXAMPLE_PATH",
            "candidates": ["cli"],
            "version_arguments": []
          }]
        }
        """)
        #expect(valid.health == .checking)
        #expect(valid.options.map(\.key) == ["model"])
        #expect(valid.options[0].label == "MODEL")
        #expect(valid.options[0].defaultValue == "b")

        let undeclared = try manifest("""
        {
          "schema_version": 1,
          "id": "example",
          "name": "Example",
          "detail": "Example CLI",
          "capabilities": [],
          "generic": {
            "command": "RELAY_EXAMPLE_PATH",
            "arguments": ["{option:missing}"]
          },
          "requirements": [{
            "name": "Example CLI",
            "environment": "RELAY_EXAMPLE_PATH",
            "candidates": ["cli"],
            "version_arguments": []
          }]
        }
        """)
        #expect(undeclared.health == .checking)
    }

    @Test
    func defersSessionPlaceholderRulesToRuntime() throws {
        let root = try temporaryDirectory()
        let genericAdapter = root.appendingPathComponent("generic-adapter")
        let cli = root.appendingPathComponent("cli")
        try executable(at: genericAdapter)
        try executable(at: cli)
        let manifest = root.appendingPathComponent("example.json")
        try Data("""
        {
          "schema_version": 1,
          "id": "example",
          "name": "Example",
          "detail": "Example CLI",
          "capabilities": [],
          "generic": {
            "command": "RELAY_EXAMPLE_PATH",
            "new_session_arguments": ["--session-id", "{session}"]
          },
          "requirements": [{
            "name": "Example CLI",
            "environment": "RELAY_EXAMPLE_PATH",
            "candidates": ["cli"],
            "version_arguments": []
          }]
        }
        """.utf8).write(to: manifest)

        let agent = AdapterCatalog.loadManifest(
            at: manifest,
            home: root,
            genericAdapter: genericAdapter
        )

        #expect(agent.health == .checking)
    }

    @Test
    func rejectsGenericCombinedWithExplicitExecutable() throws {
        let root = try temporaryDirectory()
        let manifest = root.appendingPathComponent("example.json")
        try Data("""
        {
          "schema_version": 1,
          "id": "example",
          "name": "Example",
          "detail": "Example CLI",
          "adapter_executable": "adapter",
          "capabilities": [],
          "generic": {"command": "RELAY_EXAMPLE_PATH"},
          "requirements": [{
            "name": "Example CLI",
            "environment": "RELAY_EXAMPLE_PATH",
            "candidates": ["cli"],
            "version_arguments": []
          }]
        }
        """.utf8).write(to: manifest)

        let agent = AdapterCatalog.loadManifest(at: manifest, home: root)

        guard case let .invalid(reason) = agent.health else {
            Issue.record("Combined declaration should be invalid")
            return
        }
        #expect(reason.contains("cannot both"))
    }

    @Test
    func generatesLoadableGenericManifestForLineCLI() throws {
        let root = try temporaryDirectory()
        let genericAdapter = root.appendingPathComponent("generic-adapter")
        let cli = root.appendingPathComponent("echo-cli")
        try executable(at: genericAdapter)
        try executable(at: cli)
        let manifest = root.appendingPathComponent("echo-local.json")
        let data = try AdapterCatalog.genericManifestData(
            id: "echo-local",
            name: "Echo Local",
            executablePath: cli.path,
            arguments: ["--plain", "two words"]
        )
        try data.write(to: manifest)

        let agent = AdapterCatalog.loadManifest(
            at: manifest,
            home: root,
            genericAdapter: genericAdapter
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let generic = try #require(json["generic"] as? [String: Any])
        let configuration = try #require(AdapterCatalog.lineCLIConfiguration(at: manifest))

        #expect(agent.id == "echo-local")
        #expect(agent.name == "Echo Local")
        #expect(agent.health == .checking)
        #expect(agent.registrationEnvironment["RELAY_ECHO_LOCAL_PATH"] == cli.path)
        #expect(generic["arguments"] as? [String] == ["--plain", "two words"])
        #expect(configuration == LineCLIConfiguration(
            id: "echo-local",
            name: "Echo Local",
            executablePath: cli.path,
            arguments: ["--plain", "two words"]
        ))
    }

    @Test
    func advancedGenericManifestIsNotOpenedByLineCLIEditor() throws {
        let root = try temporaryDirectory()
        let manifest = root.appendingPathComponent("advanced.json")
        try Data("""
        {
          "schema_version": 1,
          "id": "advanced",
          "name": "Advanced",
          "detail": "Advanced CLI",
          "capabilities": ["session_resume"],
          "generic": {
            "command": "RELAY_ADVANCED_PATH",
            "new_session_arguments": ["--new"],
            "resume_arguments": ["--resume", "{session}"]
          },
          "requirements": [{
            "name": "Advanced",
            "environment": "RELAY_ADVANCED_PATH",
            "candidates": ["/bin/cat"],
            "version_arguments": []
          }]
        }
        """.utf8).write(to: manifest)

        #expect(AdapterCatalog.lineCLIConfiguration(at: manifest) == nil)
    }

    @Test
    func generatedGenericManifestRejectsUnsafeInputs() {
        #expect(throws: Error.self) {
            try AdapterCatalog.genericManifestData(
                id: "../echo",
                name: "Echo",
                executablePath: "/bin/cat",
                arguments: []
            )
        }
        #expect(throws: Error.self) {
            try AdapterCatalog.genericManifestData(
                id: "echo",
                name: "Echo",
                executablePath: "bin/cat",
                arguments: []
            )
        }
        #expect(throws: Error.self) {
            try AdapterCatalog.genericManifestData(
                id: "echo",
                name: "Echo",
                executablePath: "/bin/cat",
                arguments: [String(repeating: "x", count: 513)]
            )
        }
    }

    @Test
    func distinguishesUserManifestsFromBundledOnes() {
        let userDirectory = URL(fileURLWithPath: "/Users/example/Library/Relay/adapters")
        #expect(AdapterCatalog.isUserManifest(
            userDirectory.appendingPathComponent("custom.json"),
            userDirectory: userDirectory
        ))
        #expect(!AdapterCatalog.isUserManifest(
            URL(fileURLWithPath: "/Applications/Relay.app/Contents/Resources/adapters/codex.json"),
            userDirectory: userDirectory
        ))
        #expect(!AdapterCatalog.isUserManifest(
            URL(fileURLWithPath: "/Users/example/Library/Relay/adapters-backup/custom.json"),
            userDirectory: userDirectory
        ))
    }

    @Test
    func importIsBlockedOnlyByForeignDuplicateIdentifiers() throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("custom.json")
        let existing = RelayAgent(
            id: "custom",
            name: "Custom",
            detail: "Custom CLI",
            manifestURL: root.appendingPathComponent("other.json"),
            adapterExecutablePath: nil,
            usesGenericRuntime: false,
            registrationEnvironment: [:],
            capabilities: [],
            versionExecutablePath: nil,
            versionArguments: [],
            version: nil,
            health: .checking
        )

        let conflict = AdapterCatalog.importBlockReason(
            candidateID: "custom",
            destination: destination,
            agents: [existing]
        )
        #expect(conflict?.contains("other.json") == true)

        let samePath = AdapterCatalog.importBlockReason(
            candidateID: "custom",
            destination: existing.manifestURL,
            agents: [existing]
        )
        #expect(samePath == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(at url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}
