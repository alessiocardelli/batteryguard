// Segnalazione: anonimizzazione e link mailto entro i limiti. Si compila con Report.swift da scripts/test.sh.

import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, _ line: UInt = #line) {
    if !condition {
        failures += 1
        print("FALLITO riga \(line): \(message)")
    }
}

// MARK: Anonimizzazione

let raw = """
log: /Users/mario.rossi/Applications/BatteryGuard.app non trovato
utente mario.rossi su Mario-Rossi-MacBook.local, Mac di Mario Rossi
percorso altrui: /Users/ospite/Desktop
"""
let clean = Report.anonymize(raw, home: "/Users/mario.rossi", userName: "mario.rossi", fullName: "Mario Rossi",
                             computerNames: ["Mac di Mario Rossi", "Mario-Rossi-MacBook.local"])
check(!clean.lowercased().contains("mario") && !clean.lowercased().contains("rossi"), "nessun nome rimasto: \(clean)")
check(clean.contains("~/Applications/BatteryGuard.app"), "home sostituita da ~")
check(clean.contains("utente <user> su <computer>, <computer>"), "utente e nomi del Mac: \(clean)")
check(clean.contains("/Users/<user>/Desktop"), "qualunque cartella in /Users")
check(Report.anonymize("bfD0 tipo=hex_ al 80%", home: "/Users/al", userName: "al", fullName: "", computerNames: []) == "bfD0 tipo=hex_ al 80%",
      "valori troppo corti non si sostituiscono")

// MARK: Testo del rapporto

let info = ReportInfo(appVersion: "1.0.4", osVersion: "26.5.1", osBuild: "25F80", model: "Mac14,2", chip: "Apple M2", mode: "adapter",
                      probe: ["CHTE  tipo=ui32  byte=4  valore=01 00 00 00", "schema rilevato: CHTE"],
                      heartbeat: "updated=1800000000\nstate=failed\nerror=no_charge_keys\n",
                      logTail: (1...20).map { "[2026-10-23T11:38:\($0)Z] riga di log numero \($0) con un po' di testo" })
let text = Report.text(info)
check(text.hasPrefix("App: 1.0.4\nmacOS: 26.5.1 (25F80)\nModel: Mac14,2\nChip: Apple M2\nMode: adapter"), "intestazione: \(text.prefix(100))")
check(text.contains("state=failed") && text.contains("schema rilevato: CHTE"), "battito e probe nel testo")
check(text.contains("Service log (last 20 lines):"), "log")
check(Report.text(ReportInfo(appVersion: "1", osVersion: "1", osBuild: "1", model: "1", chip: "1", mode: nil, probe: [], heartbeat: nil, logTail: []))
      .contains("Service heartbeat:\n(none)"), "battito assente")

// MARK: Link mailto

let short = Report.mailURL(subject: Report.subject(appVersion: "1.0.4"), body: "App: 1.0.4\nstate=failed & co", clipboardNote: "NOTA")
check(!short.isTruncated, "rapporto corto: intero")
check(short.url.absoluteString == "mailto:info@alessiocardelli.com?subject=BatteryGuard%20report%201.0.4&body=App%3A%201.0.4%0Astate%3Dfailed%20%26%20co",
      "codifica: \(short.url.absoluteString)")

let long = Report.mailURL(subject: "BatteryGuard report 1.0.4", body: text, clipboardNote: "Il rapporto completo è negli appunti: incollalo qui.")
check(long.isTruncated, "rapporto lungo: accorciato")
check(long.url.absoluteString.count <= Report.maxMailtoLength, "entro il limite: \(long.url.absoluteString.count)")
let decoded = URLComponents(url: long.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value ?? ""
check(decoded.hasPrefix("Il rapporto completo è negli appunti: incollalo qui.\n\nApp: 1.0.4"), "nota in cima, poi l'inizio del rapporto: \(decoded.prefix(90))")
check(decoded.hasSuffix("…"), "segno di taglio")
check(decoded.contains("schema rilevato: CHTE"), "le chiavi restano, si taglia dal log")

let tiny = Report.mailURL(subject: "s", body: String(repeating: "x", count: 5000), clipboardNote: "NOTA", maxLength: 200)
check(tiny.isTruncated && tiny.url.absoluteString.count <= 200, "riga unica troppo lunga: solo la nota")

if failures > 0 {
    print("\(failures) test falliti")
    exit(1)
}
print("Report: tutti i test passati")
