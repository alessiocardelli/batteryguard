import CryptoKit
import Foundation

// Logica pura degli aggiornamenti, senza rete né interfaccia: la compila anche scripts/test.sh.

/// Versione semantica (semver 2.0): numeri, prerelease dopo "-", metadati dopo "+" ignorati nel confronto.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    /// Accetta anche il tag di GitHub con la "v" davanti e le versioni a due numeri ("1.1").
    init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        if let plus = core.firstIndex(of: "+") { core = String(core[..<plus]) }
        var prerelease: [String] = []
        if let dash = core.firstIndex(of: "-") {
            prerelease = core[core.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !prerelease.contains(where: \.isEmpty) else { return nil }
            core = String(core[..<dash])
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count),
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = numbers.compactMap { Int($0) }
        guard values.count == numbers.count else { return nil }
        major = values[0]
        minor = values[1]
        patch = values.count == 3 ? values[2] : 0
        self.prerelease = prerelease
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = [lhs.major, lhs.minor, lhs.patch]
        let right = [rhs.major, rhs.minor, rhs.patch]
        if left != right { return left.lexicographicallyPrecedes(right) }
        // A parità di numeri la versione senza prerelease è la più recente (1.0.5-test < 1.0.5)
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// Il minimo della risposta di `GET /repos/{owner}/{repo}/releases/latest`.
struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
    }

    static func decode(_ data: Data) -> GitHubRelease? {
        try? JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

struct AvailableUpdate: Equatable {
    let version: String
    let zipURL: URL
    let checksumsURL: URL

    var zipName: String { zipURL.lastPathComponent }
}

enum UpdatePolicy {
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let appName = "BatteryGuard"
    static let checksumsName = "SHA256SUMS"

    /// Ultimo controllo assente o più vecchio di 24 ore. In valore assoluto: un orologio spostato
    /// molto indietro non deve bloccare i controlli per giorni.
    static func shouldCheck(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return abs(now.timeIntervalSince(lastCheck)) >= checkInterval
    }

    /// Release pubblicata, più recente di quella in uso e con zip e checksum: altrimenti niente da proporre.
    static func availableUpdate(from release: GitHubRelease, currentVersion: String) -> AvailableUpdate? {
        guard !release.draft, !release.prerelease,
              let latest = SemanticVersion(release.tagName),
              let current = SemanticVersion(currentVersion),
              current < latest else { return nil }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        let zipName = "\(appName)-\(version).zip"
        guard let zip = release.assets.first(where: { $0.name == zipName }),
              let sums = release.assets.first(where: { $0.name == checksumsName }) else { return nil }
        return AvailableUpdate(version: version, zipURL: zip.downloadURL, checksumsURL: sums.downloadURL)
    }

    /// Gli asset si scaricano solo da github.com in https (che poi rimanda al suo CDN).
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
    }
}

enum Checksum {
    /// Riga di `shasum -a 256`: "<64 hex>  <nome>", con "*" davanti al nome in modalità binaria.
    static func expectedSHA256(in sums: String, for fileName: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard name == fileName, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            return hash
        }
        return nil
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(ofFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256(data)
    }

    static func matches(_ data: Data, expected: String) -> Bool {
        sha256(data) == expected.lowercased()
    }
}

enum ServiceUpdate {
    /// Va proposto solo se entrambi gli hash sono leggibili e diversi: un binario illeggibile
    /// non è un buon motivo per chiedere la password.
    static func isNeeded(installedHash: String?, bundledHash: String?) -> Bool {
        guard let installedHash, let bundledHash else { return false }
        return installedHash != bundledHash
    }
}
