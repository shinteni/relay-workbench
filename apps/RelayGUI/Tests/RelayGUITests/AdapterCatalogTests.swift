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
