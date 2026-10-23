// Aggiornamenti: confronto versioni, lettura della risposta di GitHub, SHA256SUMS, servizio da aggiornare.
// Si compila insieme a UpdateCore.swift con scripts/test.sh. Primo argomento: il JSON di esempio salvato.

import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, _ line: UInt = #line) {
    if !condition {
        failures += 1
        print("FALLITO riga \(line): \(message)")
    }
}

func version(_ text: String) -> SemanticVersion {
    guard let value = SemanticVersion(text) else {
        print("versione di prova illeggibile: \(text)")
        exit(1)
    }
    return value
}

// Confronto versioni
check(version("1.0.4") > version("1.0.3"), "patch")
check(version("1.1.0") > version("1.0.9"), "minor batte patch")
check(version("2.0.0") > version("1.99.99"), "major batte minor")
check(version("1.0.10") > version("1.0.9"), "numeri, non testo")
check(version("v1.0.3") == version("1.0.3"), "tag con la v")
check(version("1.1") == version("1.1.0"), "due numeri")
check(version("1.0.5-test") > version("1.0.4"), "prerelease più recente della versione prima")
check(version("1.0.5-test") < version("1.0.5"), "prerelease meno recente della stessa versione")
check(version("1.0.5-alpha") < version("1.0.5-beta"), "prerelease in ordine alfabetico")
check(version("1.0.5-2") < version("1.0.5-10"), "prerelease numerica")
check(version("1.0.5-1") < version("1.0.5-alpha"), "numerico prima del testo")
check(version("1.0.5-alpha") < version("1.0.5-alpha.1"), "più campi = più recente")
check(version("1.0.5+abc") == version("1.0.5"), "metadati di build ignorati")
check(!(version("1.0.3") < version("1.0.3")), "uguali non sono minori")
for invalid in ["", "1", "1.0.3.4", "a.b.c", "1..3", "1.0.-1", "1.0.3-", "1.0.3-a..b", "١.٠.٣"] {
    check(SemanticVersion(invalid) == nil, "non valida: \(invalid)")
}

// Risposta di GitHub (release v1.0.3 reale, salvata)
let samplePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "github-release-latest.json"
guard let sample = FileManager.default.contents(atPath: samplePath), let release = GitHubRelease.decode(sample) else {
    print("FALLITO: JSON di esempio non leggibile in \(samplePath)")
    exit(1)
}
check(release.tagName == "v1.0.3", "tag: \(release.tagName)")
check(!release.draft && !release.prerelease, "pubblicata")
check(release.assets.map(\.name).contains("BatteryGuard-1.0.3.zip"), "asset zip")

let fromOld = UpdatePolicy.availableUpdate(from: release, currentVersion: "1.0.2")
check(fromOld?.version == "1.0.3", "1.0.2 vede la 1.0.3: \(String(describing: fromOld))")
check(fromOld?.zipURL.absoluteString == "https://github.com/alessiocardelli/batteryguard/releases/download/v1.0.3/BatteryGuard-1.0.3.zip", "url zip")
check(fromOld?.checksumsURL.lastPathComponent == "SHA256SUMS", "url checksum")
check(fromOld.map { UpdatePolicy.isTrustedDownloadURL($0.zipURL) } == true, "zip da github.com")
check(UpdatePolicy.availableUpdate(from: release, currentVersion: "1.0.3") == nil, "stessa versione: niente")
check(UpdatePolicy.availableUpdate(from: release, currentVersion: "1.0.4") == nil, "versione più vecchia: niente")
check(UpdatePolicy.availableUpdate(from: release, currentVersion: "boh") == nil, "versione in uso illeggibile: niente")

func modified(_ change: (inout [String: Any]) -> Void) -> GitHubRelease? {
    guard var object = (try? JSONSerialization.jsonObject(with: sample)) as? [String: Any] else { return nil }
    change(&object)
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return GitHubRelease.decode(data)
}
func update(_ release: GitHubRelease?) -> AvailableUpdate? {
    release.flatMap { UpdatePolicy.availableUpdate(from: $0, currentVersion: "1.0.2") }
}
check(update(modified { $0["prerelease"] = true }) == nil, "prerelease ignorata")
check(update(modified { $0["draft"] = true }) == nil, "bozza ignorata")
check(update(modified { $0["tag_name"] = "latest" }) == nil, "tag non di versione")
check(update(modified { object in
    let assets = object["assets"] as? [[String: Any]] ?? []
    object["assets"] = assets.filter { $0["name"] as? String != "SHA256SUMS" }
}) == nil, "senza SHA256SUMS")
check(update(modified { object in
    let assets = object["assets"] as? [[String: Any]] ?? []
    object["assets"] = assets.filter { $0["name"] as? String != "BatteryGuard-1.0.3.zip" }
}) == nil, "senza zip")
check(GitHubRelease.decode(Data("{\"message\":\"API rate limit exceeded\"}".utf8)) == nil, "risposta di errore")
check(GitHubRelease.decode(Data("<html>".utf8)) == nil, "non JSON")

check(!UpdatePolicy.isTrustedDownloadURL(URL(string: "http://github.com/x.zip")!), "http rifiutato")
check(!UpdatePolicy.isTrustedDownloadURL(URL(string: "https://github.com.example.org/x.zip")!), "host simile rifiutato")

// Ogni 24 ore
let now = Date(timeIntervalSince1970: 1_800_000_000)
check(UpdatePolicy.shouldCheck(lastCheck: nil, now: now), "mai controllato")
check(!UpdatePolicy.shouldCheck(lastCheck: now.addingTimeInterval(-3600), now: now), "un'ora fa")
check(UpdatePolicy.shouldCheck(lastCheck: now.addingTimeInterval(-86_400), now: now), "24 ore fa")
check(UpdatePolicy.shouldCheck(lastCheck: now.addingTimeInterval(86_400 * 3), now: now), "orologio tornato indietro di giorni")

// SHA256SUMS
let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
check(Checksum.sha256(Data("abc".utf8)) == abc, "hash noto di \"abc\"")
check(Checksum.matches(Data("abc".utf8), expected: abc.uppercased()), "esadecimale maiuscolo")
check(!Checksum.matches(Data("abd".utf8), expected: abc), "contenuto diverso")
let sums = """
d27af0478bede8edc26da0bbdd1c079f14bbaa6fd7e7dc92e40193c1b2316afe  BatteryGuard-1.0.3.dmg
0d6c965ebc5c83ae996de87470c934e85c183d32019c2b04e8ba6e061a38ea28  BatteryGuard-1.0.3.zip
\(abc) *binario.zip
nonhash  rotto.zip
"""
check(Checksum.expectedSHA256(in: sums, for: "BatteryGuard-1.0.3.zip") == "0d6c965ebc5c83ae996de87470c934e85c183d32019c2b04e8ba6e061a38ea28", "riga dello zip")
check(Checksum.expectedSHA256(in: sums, for: "binario.zip") == abc, "modalità binaria con *")
check(Checksum.expectedSHA256(in: sums, for: "rotto.zip") == nil, "hash non valido")
check(Checksum.expectedSHA256(in: sums, for: "BatteryGuard-1.0.3") == nil, "nome parziale")
check(Checksum.expectedSHA256(in: "", for: "BatteryGuard-1.0.3.zip") == nil, "file vuoto")

// Servizio da aggiornare
check(ServiceUpdate.isNeeded(installedHash: "aa", bundledHash: "bb"), "binari diversi")
check(!ServiceUpdate.isNeeded(installedHash: "aa", bundledHash: "aa"), "binari uguali")
check(!ServiceUpdate.isNeeded(installedHash: nil, bundledHash: "aa"), "installato illeggibile: non si chiede la password")
check(!ServiceUpdate.isNeeded(installedHash: "aa", bundledHash: nil), "bundle illeggibile")

if failures > 0 {
    print("\(failures) test falliti")
    exit(1)
}
print("Update: tutti i test passati")
