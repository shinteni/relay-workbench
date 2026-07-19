import Foundation
import Testing
@testable import RelayGUI

struct CommandRunnerTests {
    @Test
    @MainActor
    func drainsStandardOutputAndErrorBeforeWaitingForExit() async throws {
        let service = RelayService()
        let output = try await service.runCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "yes output | head -c 200000; yes error | head -c 200000 >&2",
            ]
        )

        #expect(output.count == 200_000)
    }
}

struct RelayProjectHistoryTests {
    @Test
    func loadsOnlyExistingDirectoriesWithCurrentProjectFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayProjectHistoryTests-\(UUID().uuidString)")
        let current = root.appendingPathComponent("current")
        let previous = root.appendingPathComponent("previous")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "RelayProjectHistoryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([
            previous.path,
            root.appendingPathComponent("missing").path,
            current.path,
        ], forKey: RelayProjectHistory.defaultsKey)

        #expect(RelayProjectHistory.load(
            currentDirectory: current.path,
            defaults: defaults
        ) == [current.path, previous.path])
    }

    @Test
    func recordingMovesProjectToFrontDeduplicatesAndCapsAtSix() {
        let paths = (0..<7).map { "/tmp/relay-project-\($0)" }
        let recorded = RelayProjectHistory.recording(paths[4], in: paths)

        #expect(recorded.count == RelayProjectHistory.limit)
        #expect(recorded.first == paths[4])
        #expect(recorded.filter { $0 == paths[4] }.count == 1)
        #expect(recorded == [paths[4], paths[0], paths[1], paths[2], paths[3], paths[5]])
    }
}

struct DaemonLaunchConfigurationTests {
    @Test
    func readsExecutableFromLaunchAgentPropertyList() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": RelayProtocol.daemonLabel,
                "ProgramArguments": [
                    "/Applications/Relay.app/Contents/Resources/bin/relayd",
                    "--socket",
                    "/tmp/relay.sock",
                ],
            ],
            format: .xml,
            options: 0
        )

        #expect(
            DaemonLaunchConfiguration.executablePath(fromPropertyList: data)
                == "/Applications/Relay.app/Contents/Resources/bin/relayd"
        )
        #expect(
            DaemonLaunchConfiguration.executablePath(
                fromPropertyList: Data("not a plist".utf8)
            ) == nil
        )
    }

    @Test
    func replacesDaemonForVersionOrBundlePathDrift() {
        let bundled = "/Applications/Relay.app/Contents/Resources/bin/relayd"

        #expect(!DaemonLaunchConfiguration.requiresReplacement(
            runningVersion: "0.9.0",
            bundledVersion: "0.9.0",
            installedExecutable: bundled,
            bundledExecutable: bundled
        ))
        #expect(!DaemonLaunchConfiguration.requiresReplacement(
            runningVersion: "0.9.0",
            bundledVersion: "0.9.0",
            installedExecutable: "/Applications/../Applications/Relay.app/Contents/Resources/bin/relayd",
            bundledExecutable: bundled
        ))
        #expect(DaemonLaunchConfiguration.requiresReplacement(
            runningVersion: "0.8.2",
            bundledVersion: "0.9.0",
            installedExecutable: nil,
            bundledExecutable: bundled
        ))
        #expect(DaemonLaunchConfiguration.requiresReplacement(
            runningVersion: "0.9.0",
            bundledVersion: "0.9.0",
            installedExecutable: "/tmp/Relay.app/Contents/Resources/bin/relayd",
            bundledExecutable: bundled
        ))
    }
}

struct RelayProtocolTests {
    @Test
    func derivesRuntimeNamesFromSharedVersion() {
        #expect(RelayProtocol.current == RelayProtocol.previous + 1)
        #expect(RelayProtocol.daemonLabel.hasSuffix(".v\(RelayProtocol.current)"))
        #expect(RelayProtocol.legacyDaemonLabel.hasSuffix(".v\(RelayProtocol.previous)"))
        #expect(RelayProtocol.daemonPropertyListName == "relayd-v\(RelayProtocol.current).plist")
        #expect(RelayProtocol.socketName == "relay-v\(RelayProtocol.current).sock")
        #expect(RelayProtocol.legacySocketName == "relay-v\(RelayProtocol.previous).sock")
    }
}
