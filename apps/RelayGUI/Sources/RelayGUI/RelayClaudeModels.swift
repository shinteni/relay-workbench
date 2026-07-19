import Foundation

enum RelayClaudeModels {
    static let families = ["fable", "opus", "sonnet", "haiku"]

    static let scanCacheKey = "claudeModelScanCache.v2"

    static func discover(
        binaryURL: URL?,
        accountConfigURL: URL,
        defaults: UserDefaults = .standard
    ) -> [String] {
        var models: [String] = []
        if let binaryURL {
            models = cachedFamilyMaxima(binaryURL: binaryURL, defaults: defaults)
        }
        for extra in accountExtras(accountConfigURL) where !models.contains(extra) {
            models.append(extra)
        }
        return models
    }

    private static func cachedFamilyMaxima(
        binaryURL: URL,
        defaults: UserDefaults
    ) -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: binaryURL.path
        ) else { return [] }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Int(
            ((attributes[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
        )
        let fingerprint = "\(binaryURL.path)|\(size)|\(modified)"
        if let cache = defaults.dictionary(forKey: scanCacheKey),
           cache["fingerprint"] as? String == fingerprint,
           let models = cache["models"] as? [String] {
            return models
        }
        guard let data = try? Data(contentsOf: binaryURL, options: .mappedIfSafe) else {
            return []
        }
        let models = familyMaxima(scan(data))
        defaults.set(
            ["fingerprint": fingerprint, "models": models],
            forKey: scanCacheKey
        )
        return models
    }

    static func resolveBinary(home: URL) -> URL? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.resolvingSymlinksInPath()
        }
        return nil
    }

    static func scan(_ data: Data) -> Set<String> {
        let prefix = Array("claude-".utf8)
        var found = Set<String>()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard raw.count >= prefix.count,
                  let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            let count = raw.count
            var index = 0
            while index <= count - prefix.count {
                var matched = true
                for offset in 0..<prefix.count {
                    if base[index + offset] != prefix[offset] {
                        matched = false
                        break
                    }
                }
                guard matched else {
                    index += 1
                    continue
                }
                var cursor = index + prefix.count
                while cursor < count {
                    let byte = base[cursor]
                    let isBodyByte = (byte >= 0x61 && byte <= 0x7A)
                        || (byte >= 0x30 && byte <= 0x39)
                        || byte == 0x2D
                    guard isBodyByte else { break }
                    cursor += 1
                }
                let length = cursor - index
                if length - prefix.count <= 40 {
                    let bytes = UnsafeBufferPointer(start: base + index, count: length)
                    if let identifier = String(bytes: bytes, encoding: .utf8),
                       isCandidate(identifier) {
                        found.insert(identifier)
                    }
                }
                index = cursor
            }
        }
        return found
    }

    static func familyMaxima(_ identifiers: Set<String>) -> [String] {
        var best: [String: String] = [:]
        for identifier in identifiers {
            guard let family = family(of: identifier) else { continue }
            if let current = best[family] {
                if isNewer(identifier, than: current) {
                    best[family] = identifier
                }
            } else {
                best[family] = identifier
            }
        }
        return families.compactMap { best[$0] }
    }

    static func accountExtras(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["additionalModelOptionsCache"] as? [[String: Any]] else {
            return []
        }
        return cached.compactMap { $0["value"] as? String }.filter { !$0.isEmpty }
    }

    private static func isCandidate(_ identifier: String) -> Bool {
        guard let family = family(of: identifier) else { return false }
        let remainder = identifier.dropFirst("claude-\(family)-".count)
        let segments = remainder.split(separator: "-", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy(\.isNumber)
        }
    }

    private static func family(of identifier: String) -> String? {
        families.first { identifier.hasPrefix("claude-\($0)-") }
    }

    private static func isNewer(_ left: String, than right: String) -> Bool {
        let leftKey = versionKey(left)
        let rightKey = versionKey(right)
        if leftKey.version != rightKey.version {
            return leftKey.version.lexicographicallyPrecedes(rightKey.version) == false
        }
        return left.count < right.count
    }

    private static func versionKey(_ identifier: String) -> (version: [Int], date: Int) {
        let numbers = identifier.split(separator: "-").compactMap { Int($0) }
        let version = numbers.filter { $0 < 1000 }
        let date = numbers.first { $0 >= 10_000_000 } ?? 0
        return (version, date)
    }
}
