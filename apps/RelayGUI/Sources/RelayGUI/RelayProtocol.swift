import Foundation

enum RelayProtocol {
    static let current: UInt32 = {
        let url = Bundle.main.url(
            forResource: "protocol-version",
            withExtension: "txt"
        ) ?? Bundle.module.url(
            forResource: "protocol-version",
            withExtension: "txt"
        )
        guard let url,
            let text = try? String(contentsOf: url, encoding: .utf8),
            let version = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            version > 0 else {
            preconditionFailure("Relay protocol-version.txt is missing or invalid")
        }
        return version
    }()

    static let previous: UInt32 = {
        precondition(current > 1, "Relay protocol version does not have a legacy predecessor")
        return current - 1
    }()

    static var daemonLabel: String {
        daemonLabel(version: current)
    }

    static var legacyDaemonLabel: String {
        daemonLabel(version: previous)
    }

    static var daemonPropertyListName: String {
        "relayd-v\(current).plist"
    }

    static var socketName: String {
        socketName(version: current)
    }

    static var legacySocketName: String {
        socketName(version: previous)
    }

    private static func daemonLabel(version: UInt32) -> String {
        "local.tenishin.relay.daemon.v\(version)"
    }

    private static func socketName(version: UInt32) -> String {
        "relay-v\(version).sock"
    }
}
